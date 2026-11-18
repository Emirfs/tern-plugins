import json
import os
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import vault
from backend import Jira, UserError, adf_markdown, adf_plain, md_to_adf


class IssueServer(Jira):
    def __init__(self):
        self.owner = "emir"
        self.title = "Eski başlık"
        self.status = {"id": "3", "name": "In Progress", "statusCategory": {"key": "indeterminate"}}
        self.stored = []

    def api(self, path, *, method="GET", body=None):
        if path == "/myself":
            return {"accountId": "emir"}
        if path.startswith("/issue/TASK-15?fields="):
            return {"id": "10015", "key": "TASK-15", "fields": {
                "summary": self.title, "status": self.status, "assignee": {"accountId": self.owner},
            }}
        if path == "/issue/TASK-15/transitions" and method == "GET":
            return {"transitions": [
                {"id": "8", "name": "Resolve", "to": {"id": "9", "name": "Resolved", "statusCategory": {"key": "done"}}},
            ]}
        if path == "/issue/TASK-15/transitions" and body == {"transition": {"id": "8"}}:
            self.status = {"id": "9", "name": "Resolved", "statusCategory": {"key": "done"}}
            return None
        if path == "/issue/TASK-15" and method == "PUT":
            self.title = body["fields"]["summary"]
            return None
        if path.startswith("/issue/TASK-15/comment?"):
            return {"total": len(self.stored), "comments": self.stored}
        if path == "/issue/TASK-15/comment" and method == "POST":
            # Jira stores ADF with attrs it adds itself (paragraph localId), so a read never equals the request.
            doc = json.loads(json.dumps(body["body"]))
            for block in doc["content"]:
                block["attrs"] = {"localId": f"p{len(self.stored)}"}
            comment = {"id": str(len(self.stored) + 1), "body": doc}
            self.stored.append(comment)
            return comment
        if path.startswith("/issue/TASK-15/comment/"):
            return self.stored[int(path.rsplit("/", 1)[-1]) - 1]
        raise AssertionError((method, path, body))


class JiraWriteTests(unittest.TestCase):
    issue = {"id": "10015", "key": "TASK-15"}

    def test_stale_title_and_reassigned_issue_are_not_written(self):
        jira = IssueServer()
        change = dict(self.issue, field="title", before="Eski başlık", value="Panodaki başlık")
        jira.title = "Başka birinin düzenlemesi"
        with self.assertRaisesRegex(UserError, "Jira’da değişmiş"):
            jira.change(change)
        self.assertEqual(jira.title, "Başka birinin düzenlemesi")
        jira.title = "Eski başlık"
        jira.owner = "someone-else"
        with self.assertRaisesRegex(UserError, "bu Jira hesabına ait değil"):
            jira.change(change)
        self.assertEqual(jira.title, "Eski başlık")

    def test_title_and_available_transition_are_applied_to_the_exact_issue(self):
        jira = IssueServer()
        self.assertEqual(jira.change(dict(self.issue, field="title", before="Eski başlık", value="Yeni başlık"))["title"], "Yeni başlık")
        with self.assertRaisesRegex(UserError, "kullanılamıyor"):
            jira.change(dict(self.issue, field="status", before="3", value="8", lane="Todo"))
        self.assertEqual(jira.change(dict(self.issue, field="status", before="3", value="8", lane="Done"))["status"], "9")

    def test_identical_reviewed_memory_is_not_posted_twice(self):
        jira = IssueServer()
        payload = dict(self.issue, text="Güç kaybı senaryosu doğrulandı.")
        self.assertEqual(jira.comment(payload), jira.comment(payload))
        self.assertEqual([c["body"]["content"][0]["content"][0]["text"] for c in jira.stored], [payload["text"]])


class AdfTests(unittest.TestCase):
    def test_comment_structure_survives_as_markdown(self):
        text = lambda t, *marks: {"type": "text", "text": t, "marks": list(marks)}
        doc = {"type": "doc", "version": 1, "content": [
            {"type": "heading", "attrs": {"level": 3, "localId": "h"}, "content": [text("Kök neden")]},
            {"type": "bulletList", "content": [
                {"type": "listItem", "content": [{"type": "paragraph", "content": [text("ST-LINK", {"type": "strong"}), text(" takılıyor")]}]},
                {"type": "listItem", "content": [{"type": "paragraph", "content": [
                    text("rapor", {"type": "link", "attrs": {"href": "https://example.com/r"}})]}]},
            ]},
            {"type": "table", "content": [
                {"type": "tableRow", "content": [{"type": "tableHeader", "content": [{"type": "paragraph", "content": [text("Kod")]}]},
                                                 {"type": "tableHeader", "content": [{"type": "paragraph", "content": [text("Anlam")]}]}]},
                {"type": "tableRow", "content": [{"type": "tableCell", "content": [{"type": "paragraph", "content": [text("STM-C01")]}]},
                                                 {"type": "tableCell", "content": [{"type": "paragraph", "content": [text("a|b")]}]}]},
            ]},
            {"type": "mediaSingle", "content": [{"type": "media", "attrs": {"id": "x"}}]},
        ]}
        self.assertEqual(adf_markdown(doc), "\n\n".join([
            "### Kök neden",
            "- **ST-LINK** takılıyor\n- [rapor](https://example.com/r)",
            "| Kod | Anlam |\n| --- | --- |\n| STM-C01 | a\\|b |",
            "*[ek]*",
        ]))
        self.assertEqual(adf_plain(doc).splitlines()[0], "Kök neden")


class VaultTests(unittest.TestCase):
    issue = dict(key="TASK-15", id="10015", title="Kurtarma", status_name="Devam", lane="Doing",
                 url="https://x.atlassian.net/browse/TASK-15", updated="2026-11-18 10:00",
                 comments=[dict(id="7", mine=True, created="2026-11-10 09:00", text="### İlk rapor\n\nayrıntı",
                                url="https://x.atlassian.net/browse/TASK-15?focusedCommentId=7"),
                           dict(id="8", mine=False, created="2026-11-11 09:00", text="başkası", url="u")])

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        os.environ["TERN_HAFIZA_DIR"] = self.dir.name

    def tearDown(self):
        del os.environ["TERN_HAFIZA_DIR"]
        self.dir.cleanup()

    def test_user_sections_survive_and_jira_owned_parts_follow_jira(self):
        vault.sync([dict(self.issue)])
        path = vault.note_path("TASK-15")
        text = path.read_text(encoding="utf-8")
        self.assertIn("[7](https://x.atlassian.net/browse/TASK-15?focusedCommentId=7) · İlk rapor", text)
        self.assertNotIn("başkası", text)
        edited = text.replace("## Log\n", "## Log\n\n- 2026-11-12 · elle yazılan satır\n")
        edited = edited.replace("---\n", "---\nowner: emir\n", 1).replace("title: Kurtarma", "title: eski")
        path.write_text(edited, encoding="utf-8")
        moved = dict(self.issue, title="Kurtarma testi", comments=[])
        drafts, written = vault.sync([moved])
        after = path.read_text(encoding="utf-8")
        self.assertEqual((drafts, written), ([], [path]))
        self.assertIn("- 2026-11-12 · elle yazılan satır", after)
        self.assertIn("owner: emir", after)
        self.assertIn("title: Kurtarma testi", after)
        self.assertNotIn("title: eski", after)
        self.assertNotIn("İlk rapor", after)
        self.assertEqual(vault.sync([moved])[1], [])

    def test_draft_is_offered_once_filled_and_cleared_only_if_unchanged(self):
        vault.sync([dict(self.issue)])
        path = vault.note_path("TASK-15")
        draft = "Kurtarma senaryosu geçti.\n\n- güç kaybı denendi"
        text = path.read_text(encoding="utf-8")
        path.write_text(text.replace("## Jira draft\n", f"## Jira draft\n\n{draft}\n"), encoding="utf-8")
        drafts, _ = vault.sync([dict(self.issue)])
        self.assertEqual([d["text"] for d in drafts], [draft])
        vault.clear_draft("TASK-15", "başka metin")
        self.assertEqual(len(vault.sync([dict(self.issue)])[0]), 1)
        vault.clear_draft("TASK-15", draft)
        self.assertEqual(vault.sync([dict(self.issue)])[0], [])

    def test_markdown_draft_compares_equal_after_jira_adds_attrs(self):
        adf = md_to_adf("**Sonuç** geçti\nikinci satır\n\n- a\n- b\n\n```c\nx = 1;\n```")
        self.assertEqual([b["type"] for b in adf["content"]], ["paragraph", "bulletList", "codeBlock"])
        stored = json.loads(json.dumps(adf))
        for block in stored["content"]:
            block["attrs"] = dict(block.get("attrs") or {}, localId="z")
        self.assertEqual(adf_plain(stored), adf_plain(adf))
