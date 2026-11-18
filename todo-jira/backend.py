"""Stdin/stdout JSON adapter for the local Tern window. No credentials in argv or output."""
import base64
from datetime import datetime, timezone
import hashlib
import json
from http.client import HTTPException
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from urllib.error import HTTPError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

import vault

KEY = re.compile(r"[A-Z][A-Z0-9_]*-[1-9][0-9]*")
SLUG = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_-]*")
FIELDS = "summary,status,duedate,assignee"
LANES = {"new": "Todo", "indeterminate": "Doing", "done": "Done"}


class UserError(Exception):
    pass


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def required(pattern, value):
    if not isinstance(value, str) or not pattern.fullmatch(value):
        raise UserError("Kart, pano veya profil kimliği geçersiz.")
    return value


def board_summary(summary):
    return " ".join(summary.strip().splitlines())


def issue_view(issue):
    f = issue["fields"]
    category = f["status"]["statusCategory"]["key"]
    return dict(key=required(KEY, issue["key"]), id=issue["id"],
                title=board_summary(f["summary"]), due=f.get("duedate") or "",
                status=f["status"]["id"], status_name=f["status"]["name"], lane=LANES.get(category, "Todo"))


INLINE_MARKS = {"strong": "**", "em": "*", "strike": "~~", "code": "`"}


def adf_inline(nodes):
    out = []
    for node in nodes or ():
        kind, attrs = node.get("type"), node.get("attrs") or {}
        if kind == "text":
            text = node.get("text", "")
            for mark in node.get("marks", ()):
                wrap = INLINE_MARKS.get(mark.get("type"))
                if wrap:
                    text = wrap + text + wrap
                elif mark.get("type") == "link" and (mark.get("attrs") or {}).get("href"):
                    text = f"[{text}]({mark['attrs']['href']})"
            out.append(text)
        elif kind == "hardBreak":
            out.append("  \n")
        elif kind in ("mention", "emoji", "status"):
            out.append(attrs.get("text") or attrs.get("shortName") or "")
        elif kind in ("inlineCard", "blockCard"):
            out.append(attrs.get("url", ""))
        elif kind == "date" and str(attrs.get("timestamp", "")).isdigit():
            out.append(datetime.fromtimestamp(int(attrs["timestamp"]) / 1000, timezone.utc).strftime("%Y-%m-%d"))
        else:
            out.append(adf_inline(node.get("content")))
    return "".join(out)


def adf_markdown(node, indent=""):
    """Jira's ADF as Markdown: enough for comments and descriptions; unknown blocks keep their text."""
    kind, attrs, content = node.get("type"), node.get("attrs") or {}, node.get("content") or []
    if kind == "doc" or kind in ("panel", "layoutSection", "layoutColumn", "nestedExpand", "expand"):
        blocks = [adf_markdown(child, indent) for child in content]
        if kind in ("expand", "nestedExpand") and attrs.get("title"):
            blocks.insert(0, f"**{attrs['title']}**")
        return "\n\n".join(b for b in blocks if b)
    if kind == "paragraph":
        return adf_inline(content)
    if kind == "heading":
        return "#" * min(max(int(attrs.get("level", 1)), 1), 6) + " " + adf_inline(content)
    if kind in ("bulletList", "orderedList"):
        lines = []
        for n, item in enumerate(content, int(attrs.get("order", 1))):
            bullet = f"{n}. " if kind == "orderedList" else "- "
            body = "\n".join(adf_markdown(child, indent + "  ") for child in item.get("content") or [])
            lines.append(indent + bullet + body.lstrip())
        return "\n".join(lines)
    if kind == "codeBlock":
        return f"```{attrs.get('language') or ''}\n{adf_inline(content)}\n```"
    if kind == "blockquote":
        inner = "\n\n".join(adf_markdown(child) for child in content)
        return "\n".join("> " + line for line in inner.splitlines())
    if kind == "rule":
        return "---"
    if kind == "table":
        rows = [[" ".join(adf_markdown(block) for block in cell.get("content") or []).replace("\n", " ").replace("|", "\\|")
                 for cell in row.get("content") or []] for row in content]
        if not rows:
            return ""
        width = max(len(row) for row in rows)
        rows = [row + [""] * (width - len(row)) for row in rows]
        lines = ["| " + " | ".join(rows[0]) + " |", "|" + " --- |" * width]
        return "\n".join(lines + ["| " + " | ".join(row) + " |" for row in rows[1:]])
    if kind in ("mediaSingle", "mediaGroup", "media"):
        return "*[ek]*"
    return adf_inline(content) if content else ""


def adf_plain(node):
    """The text a reader sees, for comparing a stored comment with what was sent (Jira adds attrs on read)."""
    if node.get("type") == "text":
        return node.get("text", "")
    parts = [adf_plain(child) for child in node.get("content") or []]
    return ("\n" if node.get("type") == "doc" else "").join(parts)


def comment_view(comment, me, url):
    author = comment.get("author") or {}
    return dict(id=comment["id"], author=author.get("displayName") or "?", mine=author.get("accountId") == me,
                created=comment["created"][:16].replace("T", " "), edited=comment.get("updated", comment["created"]) != comment["created"],
                text=adf_markdown(comment.get("body") or {}), url=f"{url}?focusedCommentId={comment['id']}")


class Jira:
    def __init__(self):
        raw = os.environ.get("TERN_JIRA_URL", "")
        url = urlsplit(raw)
        if (url.scheme != "https" or not url.hostname or not url.hostname.endswith(".atlassian.net")
                or url.netloc != url.hostname or url.path not in ("", "/") or url.query or url.fragment):
            raise UserError("TERN_JIRA_URL, https://<site>.atlassian.net biçiminde olmalı.")
        self.site = "https://" + url.hostname
        self.root = self.site + "/rest/api/3"
        account = Path(os.environ.get("TERN_JIRA_CREDENTIAL_FILE", str(Path.home() / ".jira_token.txt")))
        try:
            email, token = (line.strip() for line in account.read_text(encoding="utf-8-sig").splitlines() if line.strip())
        except (OSError, ValueError):
            raise UserError("Jira kimlik dosyasında e-posta ve API anahtarı ayrı satırlarda olmalı.") from None
        if not email or not token:
            raise UserError("Jira kimlik dosyası eksik.")
        self.auth = "Basic " + base64.b64encode(f"{email}:{token}".encode()).decode("ascii")
        self.opener = build_opener(NoRedirect())

    def api(self, route, *, method="GET", body=None):
        request = Request(self.root + route, method=method,
                          headers={"Authorization": self.auth, "Accept": "application/json",
                                   "Content-Type": "application/json"},
                          data=json.dumps(body).encode() if body is not None else None)
        try:
            with self.opener.open(request, timeout=12) as response:
                data = response.read()
                return json.loads(data) if data else None
        except HTTPError as exc:
            try:
                reply = json.loads(exc.read() or b"{}")
                detail = " ".join([*reply.get("errorMessages", []), *map(str, (reply.get("errors") or {}).values())])
            except (ValueError, OSError, AttributeError):
                detail = ""
            raise UserError(f"Jira HTTP {exc.code}; işlem onaylanmadı. {detail[:240]}".strip()) from None
        except (OSError, HTTPException):
            # URLError, zaman aşımı ve yanıt okunurken kopan bağlantı: istek Jira'ya ulaşmış olabilir.
            raise UserError("Jira yanıtı alınamadı. Tekrar göndermeden önce kartı yenileyin; yazma tamamlanmış olabilir.") from None

    def search(self, fields):
        issues = []
        search = dict(jql="assignee = currentUser() ORDER BY updated DESC", fields=fields, maxResults=100)
        tokens = set()
        while True:
            page = self.api("/search/jql", method="POST", body=search)
            issues.extend(page["issues"])
            token = page.get("nextPageToken")
            if page.get("isLast") or not token:
                return issues
            if token in tokens:
                raise UserError("Jira arama sayfası tekrarladı; pano değiştirilmedi.")
            tokens.add(token)
            search["nextPageToken"] = token

    def assigned(self):
        return [issue_view(issue) for issue in self.search(FIELDS.split(","))]

    def comments(self, key, inline=None):
        """Every comment, oldest first. Search returns them inline but may stop short of `total`."""
        found = list((inline or {}).get("comments") or [])
        total = inline.get("total", 0) if inline is not None else None
        while total is None or len(found) < total:
            page = self.api(f"/issue/{key}/comment?" + urlencode({"startAt": len(found), "maxResults": 100, "orderBy": "created"}))
            total = page["total"]
            if not page["comments"]:
                break
            found.extend(page["comments"])
        return found

    def overview(self):
        me = self.api("/myself")["accountId"]
        issues = []
        for raw in self.search(FIELDS.split(",") + ["comment", "description", "updated"]):
            view = issue_view(raw)
            url = f"{self.site}/browse/{view['key']}"
            fields = raw["fields"]
            view.update(url=url, updated=(fields.get("updated") or "")[:16].replace("T", " "),
                        description=adf_markdown(fields["description"]) if fields.get("description") else "",
                        comments=[comment_view(c, me, url) for c in self.comments(view["key"], fields.get("comment") or {})])
            issues.append(view)
        return issues

    def context(self, key):
        """What an agent needs to start on a card: the card as Jira has it now, not the board's one-line title."""
        key = required(KEY, key)
        fields = self.api(f"/issue/{key}?fields=summary,status,description,comment")["fields"]
        parts = [f"Jira kartı: {key} — {board_summary(fields['summary'])}", f"Durum: {fields['status']['name']}",
                 f"Bağlantı: {self.site}/browse/{key}"]
        if fields.get("description"):
            parts.append("Açıklama:\n" + adf_markdown(fields["description"])[:6000])
        recent = self.comments(key, fields.get("comment") or {})[-3:]
        for c in recent:
            parts.append(f"Yorum ({(c.get('author') or {}).get('displayName', '?')}, {c['created'][:10]}):\n"
                         + adf_markdown(c.get("body") or {})[:3000])
        return "\n\n".join(parts)

    def owned(self, item):
        key = required(KEY, item["key"])
        data = self.api(f"/issue/{key}?fields=" + FIELDS)
        who = self.api("/myself")["accountId"]
        if ((data["fields"].get("assignee") or {}).get("accountId") != who
                or item["id"] != data["id"] or key != data["key"]):
            raise UserError(f"{key} artık bu Jira hesabına ait değil veya anahtarı değişmiş.")
        return issue_view(data)

    def transitions(self, issue, lane):
        return [{"id": t["id"], "name": t["to"]["name"], "action": t["name"], "status": t["to"]["id"]}
                for t in self.api(f"/issue/{issue['key']}/transitions")["transitions"]
                if LANES.get(t["to"]["statusCategory"]["key"]) == lane]

    def change(self, data):
        current = self.owned(data)
        field = data["field"]
        if field not in ("title", "due", "status") or current[field] != data["before"]:
            raise UserError(f"{current['key']} Jira’da değişmiş. Önce 'Jira’dan yenile' yapın.")
        route = f"/issue/{current['key']}"
        value = data["value"]
        if field == "status":
            transition = next((t for t in self.transitions(current, data["lane"]) if t["id"] == value), None)
            if transition is None:
                raise UserError("Bu durum geçişi artık kullanılamıyor.")
            self.api(route + "/transitions", method="POST", body={"transition": {"id": value}})
            value = transition["status"]
        else:
            self.api(route, method="PUT", body={"fields": {"summary" if field == "title" else "duedate": value or None}})
        updated = self.owned(data)
        expected = board_summary(value) if field == "title" else value
        if updated[field] != expected:
            raise UserError("Jira değişikliği doğrulanamadı; tekrar göndermeden önce kartı yenileyin.")
        return updated

    def comment(self, data):
        issue = self.owned(data)
        route = f"/issue/{issue['key']}/comment"
        adf = md_to_adf(data["text"])
        # Jira returns stored ADF with extra attrs (paragraph localId), so compare what a reader sees.
        sent = adf_plain(adf)
        for existing in self.comments(issue["key"]):
            if adf_plain(existing.get("body") or {}) == sent:
                return existing["id"]
        added = self.api(route, method="POST", body={"body": adf})["id"]
        verified = self.api(route + "/" + added)
        if adf_plain(verified.get("body") or {}) != sent:
            raise UserError("Jira yorumu geri okundu ancak önizlemeyle eşleşmedi; kartı kontrol edin.")
        return added


INLINE = re.compile(r"\*\*(.+?)\*\*|`([^`]+)`|\[([^\]]+)\]\((https?://[^)\s]+)\)")


def md_inline(text):
    out, at = [], 0
    for m in INLINE.finditer(text):
        if m.start() > at:
            out.append({"type": "text", "text": text[at:m.start()]})
        if m.group(1):
            out.append({"type": "text", "text": m.group(1), "marks": [{"type": "strong"}]})
        elif m.group(2):
            out.append({"type": "text", "text": m.group(2), "marks": [{"type": "code"}]})
        else:
            out.append({"type": "text", "text": m.group(3), "marks": [{"type": "link", "attrs": {"href": m.group(4)}}]})
        at = m.end()
    if at < len(text):
        out.append({"type": "text", "text": text[at:]})
    return out


def md_to_adf(text):
    """The Markdown a draft is written in, as Jira ADF: headings, lists, code fences, paragraphs."""
    blocks, lines, i = [], text.strip().splitlines(), 0
    while i < len(lines):
        line = lines[i]
        if not line.strip():
            i += 1
        elif line.startswith("```"):
            end = next((j for j in range(i + 1, len(lines)) if lines[j].startswith("```")), len(lines))
            code = "\n".join(lines[i + 1:end])
            block = {"type": "codeBlock", "content": [{"type": "text", "text": code}] if code else []}
            if line[3:].strip():
                block["attrs"] = {"language": line[3:].strip()}
            blocks.append(block)
            i = end + 1
        elif m := re.match(r"(#{1,6}) +(.*)", line):
            blocks.append({"type": "heading", "attrs": {"level": len(m.group(1))}, "content": md_inline(m.group(2))})
            i += 1
        elif re.match(r"([-*]|\d+\.) +", line):
            ordered = bool(re.match(r"\d+\.", line))
            items = []
            while i < len(lines) and (m := re.match(r"(?:[-*]|\d+\.) +(.*)", lines[i])):
                items.append({"type": "listItem", "content": [{"type": "paragraph", "content": md_inline(m.group(1))}]})
                i += 1
            blocks.append({"type": "orderedList" if ordered else "bulletList", "content": items})
        else:
            para = []
            while i < len(lines) and lines[i].strip() and not re.match(r"```|#{1,6} |[-*] |\d+\. ", lines[i]):
                if para:
                    para.append({"type": "hardBreak"})
                para.extend(md_inline(lines[i]))
                i += 1
            blocks.append({"type": "paragraph", "content": para})
    return {"type": "doc", "version": 1, "content": blocks}


def hermes(args, *, text=None):
    local = Path(os.environ.get("LOCALAPPDATA", "")) / "hermes/bin/hermes.exe"
    exe = str(local) if local.is_file() else shutil.which("hermes")
    if not exe:
        raise UserError("Hermes komutu bulunamadı.")
    try:
        result = subprocess.run([exe, "kanban", *args], input=text, capture_output=True,
                                encoding="utf-8", errors="replace", timeout=25,
                                env={**os.environ, "PYTHONIOENCODING": "utf-8", "NO_COLOR": "1"})
    except (OSError, subprocess.TimeoutExpired):
        raise UserError("Hermes yanıtı alınamadı. Panoyu kontrol edin.") from None
    if result.returncode:
        detail = " ".join(result.stderr.split())[-240:]
        raise UserError(f"Hermes Kanban çıkış kodu {result.returncode}; işlemi panoda kontrol edin. {detail}".strip())
    return json.loads(result.stdout)


def dispatch(data):
    op = data["op"]
    if op == "memory":
        # Card notes in the vault: refreshed from Jira, committed, and their drafts returned.
        issues = Jira().overview()
        drafts, written = vault.sync(issues)
        warning = vault.commit(written, f"docs(jira): sync {len(written)} card notes from Jira")
        return {"drafts": drafts, "warning": warning, "vault": str(vault.root())}
    if op == "kanban-options":
        boards = [{"slug": b["slug"], "name": b["name"]} for b in hermes(["boards", "list", "--json"])]
        profiles = [p["name"] for p in hermes(["assignees", "--json"]) if p["on_disk"]]
        return {"boards": boards, "profiles": profiles}
    if op == "kanban-create":
        board = required(SLUG, data["board"])
        title = data["title"]
        body = data["body"]
        if data.get("key"):
            body += "\n\n" + Jira().context(data["key"])
        # Same card, profile and context → the existing task; a new comment or description gives a new one.
        marker = hashlib.sha256("\0".join((data["identity"], data.get("assignee", ""), body)).encode()).hexdigest()
        args = ["--board", board, "create", "--json", "--created-by", "tern-todo", "--idempotency-key", "tern-todo-" + marker]
        if data.get("assignee"):
            args += ["--assignee", required(SLUG, data["assignee"])]
        return hermes([*args, "--body-file", "-", "--", title], text=body)
    jira = Jira()
    if op == "assigned":
        return jira.assigned()
    if op == "overview":
        issues = jira.overview()
        _, written = vault.sync(issues)
        vault.commit(written, f"docs(jira): sync {len(written)} card notes from Jira")
        for issue in issues:
            issue["note"] = str(vault.note_path(issue["key"]))
        return issues
    if op == "transitions":
        issue = jira.owned(data)
        if issue["status"] != data["before"]:
            raise UserError(f"{issue['key']} Jira’da değişmiş. Önce 'Jira’dan yenile' yapın.")
        return jira.transitions(issue, data["lane"])
    if op == "change":
        return jira.change(data)
    if op == "comment":
        added = jira.comment(data)
        vault.clear_draft(data["key"], data["text"])
        return added
    raise UserError("Bilinmeyen Todo işlemi.")


if __name__ == "__main__":
    try:
        print(json.dumps({"data": dispatch(json.load(sys.stdin))}, ensure_ascii=True))
    except UserError as exc:
        print(json.dumps({"error": str(exc)}))
    except (ValueError, TypeError, KeyError, OSError) as exc:
        print(json.dumps({"error": f"Todo · Jira: veri okunamadı ({type(exc).__name__})."}))
