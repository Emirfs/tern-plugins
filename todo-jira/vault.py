"""Jira card notes in the shared Markdown vault (`<vault>/jira/<KEY>.md`).

The plugin owns only the frontmatter fields below and the "Sent to Jira" section, both rebuilt from
Jira on every sync. Every other section belongs to the user and the agents and is kept byte for byte.
"""
import hashlib
import os
from pathlib import Path
import re
import subprocess

OWNED = ("type", "key", "title", "status", "lane", "jira", "updated")
SENT = "Sent to Jira"
DRAFT = "Jira draft"
SECTIONS = (
    ("Summary", "Current state in at most 10 lines. Rewrite it; do not append."),
    ("Log", "- YYYY-MM-DD · [[project]] · what was done (source: commit / session id)"),
    ("Open", "What is left, one line each."),
    ("Decisions", "Link decision notes: [[decision-name]]"),
    (DRAFT, "The reporter writes the next Jira comment here. Tern shows it under Todo · Jira: Doldur; "
            "once approved and posted it is cleared and appears under Sent to Jira."),
    (SENT, "Rebuilt from Jira by the plugin; edits here are overwritten."),
)
HEADING = re.compile(r"^## ([^\n]+?)[ \t]*$", re.M)
COMMENT = re.compile(r"<!--.*?-->", re.S)


def root():
    return Path(os.environ.get("TERN_HAFIZA_DIR") or Path.home() / "GitHub/araclar/hafiza")


def note_path(key):
    return root() / "jira" / f"{key}.md"


def split(text):
    """(frontmatter lines, body) — frontmatter without its `---` fences."""
    if text.startswith("---\n"):
        end = text.find("\n---\n", 4)
        if end != -1:
            return text[4:end].split("\n"), text[end + 5:]
    return [], text


def sections(body):
    """[(heading or None for the preamble, text)] in file order."""
    marks = list(HEADING.finditer(body))
    out = [(None, body[:marks[0].start()] if marks else body)]
    for i, m in enumerate(marks):
        out.append((m.group(1), body[m.end():marks[i + 1].start() if i + 1 < len(marks) else len(body)]))
    return out


def join(parts):
    return "".join(part if name is None else f"## {name}{part}" for name, part in parts)


def frontmatter(lines, values):
    kept = [line for line in lines if line.split(":", 1)[0].strip() not in OWNED]
    owned = [f"{k}: {quote(values[k])}" for k in OWNED]
    return "---\n" + "\n".join(owned + [line for line in kept if line.strip()]) + "\n---\n"


def quote(value):
    value = str(value)
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"' if re.search(r"[:#\[\]{}\"'&*!|>%@`]|^\s|\s$", value) else value


def sent_list(comments):
    lines = []
    for c in comments:
        if c["mine"]:
            first = next((line.strip("# *").strip() for line in c["text"].splitlines() if line.strip()), "")
            lines.append(f"- {c['created'][:10]} · [{c['id']}]({c['url']}) · {first[:120]}")
    return "\n\n" + ("\n".join(lines) if lines else "_Henüz yorum yok._") + "\n\n"


def render(issue, existing):
    values = dict(type="jira", key=issue["key"], title=issue["title"], status=issue["status_name"],
                  lane=issue["lane"], jira=issue["url"], updated=issue.get("updated", "")[:10])
    lines, body = split(existing) if existing else ([], "")
    parts = sections(body) if existing else [(None, f"\n# {issue['key']} · {issue['title']}\n\n")] + [
        (name, f"\n\n<!-- {hint} -->\n\n") for name, hint in SECTIONS]
    names = [name for name, _ in parts]
    if SENT not in names:
        parts.append((SENT, ""))
    parts = [(name, sent_list(issue["comments"]) if name == SENT else text) for name, text in parts]
    return frontmatter(lines, values) + join(parts).rstrip("\n") + "\n"


def draft_text(body):
    for name, text in sections(body):
        if name == DRAFT:
            return COMMENT.sub("", text).strip()
    return ""


def memory_view(text):
    """What the Jira pane shows: filled sections only, without the plugin-owned list."""
    _, body = split(text)
    filled = [(n, COMMENT.sub("", t).strip()) for n, t in sections(body) if n not in (None, SENT)]
    return "\n\n".join(f"### {n}\n\n{t}" for n, t in filled if t)


def sync(issues):
    """Writes each card's note when it changed; returns (drafts, written paths)."""
    written, drafts = [], []
    for issue in issues:
        path = note_path(issue["key"])
        old = path.read_text(encoding="utf-8") if path.is_file() else None
        new = render(issue, old)
        if new != old:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(new, encoding="utf-8", newline="\n")
            written.append(path)
        issue["memory"] = memory_view(new)
        text = draft_text(split(new)[1])
        if text:
            drafts.append(dict(key=issue["key"], id=issue["id"], text=text,
                               digest=hashlib.sha256(text.encode()).hexdigest()))
    return drafts, written


def clear_draft(key, text):
    """After the comment is in Jira: empty the draft section, only if it still holds what was sent."""
    path = note_path(key)
    if not path.is_file():
        return
    lines, body = split(path.read_text(encoding="utf-8"))
    hint = dict(SECTIONS)[DRAFT]
    parts = [(n, f"\n\n<!-- {hint} -->\n\n" if n == DRAFT and COMMENT.sub("", t).strip() == text else t)
             for n, t in sections(body)]
    path.write_text(("---\n" + "\n".join(lines) + "\n---\n" if lines else "") + join(parts), encoding="utf-8", newline="\n")
    commit([path], f"docs(jira): clear the {key} draft sent to Jira")


def commit(paths, message):
    """Each write is one commit, so the user can read and revert what changed. Returns a warning or None."""
    repo = root()
    if not paths or not (repo / ".git").exists():
        return None
    rel = [str(p.relative_to(repo)) for p in paths]
    run = lambda *args: subprocess.run(["git", "-C", str(repo), *args], capture_output=True, encoding="utf-8",
                                       errors="replace", timeout=30)
    try:
        add = run("add", "--", *rel)
        done = add if add.returncode else run("commit", "-q", "-m", message, "--", *rel)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return f"Hafıza kasası commit edilemedi: {type(exc).__name__}"
    if done.returncode:
        return "Hafıza kasası commit edilemedi: " + " ".join((done.stderr or done.stdout).split())[-200:]
    return None
