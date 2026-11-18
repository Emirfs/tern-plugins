"""Stdin/stdout JSON adapter for the local Tern window. No credentials in argv or output."""
import base64
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

KEY = re.compile(r"[A-Z][A-Z0-9_]*-[1-9][0-9]*")
MENTIONS = re.compile(r"(?<![\w-])" + KEY.pattern + r"(?![\w-])")
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


class Jira:
    def __init__(self):
        raw = os.environ.get("TERN_JIRA_URL", "")
        url = urlsplit(raw)
        if (url.scheme != "https" or not url.hostname or not url.hostname.endswith(".atlassian.net")
                or url.netloc != url.hostname or url.path not in ("", "/") or url.query or url.fragment):
            raise UserError("TERN_JIRA_URL, https://<site>.atlassian.net biçiminde olmalı.")
        self.root = "https://" + url.hostname + "/rest/api/3"
        account = Path(os.environ.get("TERN_JIRA_CREDENTIAL_FILE", str(Path.home() / ".jira_token.txt")))
        try:
            email, token = (line.strip() for line in account.read_text(encoding="utf-8-sig").splitlines())
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
            raise UserError(f"Jira HTTP {exc.code}; işlem onaylanmadı.") from None
        except (URLError, TimeoutError):
            raise UserError("Jira yanıtı alınamadı. Tekrar göndermeden önce kartı yenileyin; yazma tamamlanmış olabilir.") from None

    def assigned(self):
        issues = []
        search = dict(jql="assignee = currentUser() ORDER BY updated DESC", fields=FIELDS.split(","), maxResults=100)
        tokens = set()
        while True:
            page = self.api("/search/jql", method="POST", body=search)
            issues.extend(map(issue_view, page["issues"]))
            token = page.get("nextPageToken")
            if page.get("isLast") or not token:
                return issues
            if token in tokens:
                raise UserError("Jira arama sayfası tekrarladı; pano değiştirilmedi.")
            tokens.add(token)
            search["nextPageToken"] = token

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
        text = data["text"]
        adf = {"type": "doc", "version": 1, "content": [{"type": "paragraph", "content": [{"type": "text", "text": text}]}]}
        def find():
            start = 0
            while True:
                page = self.api(route + "?" + urlencode({"startAt": start, "maxResults": 100, "orderBy": "-created"}))
                for comment in page["comments"]:
                    if comment.get("body") == adf:
                        return comment["id"]
                start += len(page["comments"])
                if not page["comments"] or start >= page["total"]:
                    return None
        existing = find()
        if existing is not None:
            return existing
        added = self.api(route, method="POST", body={"body": adf})["id"]
        verified = self.api(route + "/" + added)
        if verified.get("body") != adf:
            raise UserError("Jira yorumu geri okundu ancak önizlemeyle eşleşmedi; kartı kontrol edin.")
        return added


def memory_drafts(issues, seen, index):
    if not issues:
        return []
    if not index.is_file():
        raise UserError("Mnemo hafıza indeksi bulunamadı (TERN_TODO_MEMORY_INDEX).")
    keys = {required(KEY, i["key"]): i for i in issues}
    with closing(sqlite3.connect(index.resolve().as_uri() + "?mode=ro", uri=True)) as db:
        rows = db.execute("""SELECT title, summary FROM notes
            WHERE status = 'active' AND verification = 'verified' AND trim(summary) != ''
              AND type IN ('decision', 'lesson', 'daily', 'project', 'note')
            ORDER BY coalesce(updated, created) DESC, id DESC""").fetchall()
    considered = set()
    drafts = []
    for title, summary in rows:
        text = " ".join(summary.split())
        matched = set(MENTIONS.findall(title + " " + text))
        if len(matched) != 1 or not 0 < len(text) <= 260:
            continue
        key = matched.pop()
        if key not in keys or key in considered:
            continue
        considered.add(key)
        digest = hashlib.sha256(text.encode()).hexdigest()
        if digest != seen.get(key):
            drafts.append(dict(key=key, id=keys[key]["id"], text=text, digest=digest))
    return drafts


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
        raise UserError(f"Hermes Kanban çıkış kodu {result.returncode}; işlemi panoda kontrol edin.")
    return json.loads(result.stdout)


def dispatch(data):
    op = data["op"]
    if op == "memory":
        default = Path.home() / "GitHub/araclar/mnemo-vault/.mnemo/index.sqlite"
        return memory_drafts(data["issues"], data["seen"], Path(os.environ.get("TERN_TODO_MEMORY_INDEX", default)))
    if op == "kanban-options":
        boards = [{"slug": b["slug"], "name": b["name"]} for b in hermes(["boards", "list", "--json"])]
        profiles = [p["name"] for p in hermes(["assignees", "--json"]) if p["on_disk"]]
        return {"boards": boards, "profiles": profiles}
    if op == "kanban-create":
        board = required(SLUG, data["board"])
        title = data["title"]
        marker = hashlib.sha256((data["identity"] + "\0" + data.get("assignee", "")).encode()).hexdigest()
        args = ["--board", board, "create", "--json", "--created-by", "tern-todo", "--idempotency-key", "tern-todo-" + marker]
        if data.get("assignee"):
            args += ["--assignee", required(SLUG, data["assignee"])]
        return hermes([*args, "--body-file", "-", "--", title], text=data["body"])
    jira = Jira()
    if op == "assigned":
        return jira.assigned()
    if op == "transitions":
        issue = jira.owned(data)
        if issue["status"] != data["before"]:
            raise UserError(f"{issue['key']} Jira’da değişmiş. Önce 'Jira’dan yenile' yapın.")
        return jira.transitions(issue, data["lane"])
    if op == "change":
        return jira.change(data)
    if op == "comment":
        return jira.comment(data)
    raise UserError("Bilinmeyen Todo işlemi.")


if __name__ == "__main__":
    try:
        print(json.dumps({"data": dispatch(json.load(sys.stdin))}, ensure_ascii=True))
    except UserError as exc:
        print(json.dumps({"error": str(exc)}))
    except (ValueError, TypeError, KeyError, OSError, sqlite3.Error) as exc:
        print(json.dumps({"error": f"Todo · Jira: veri okunamadı ({type(exc).__name__})."}))
