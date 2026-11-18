import pathlib
import sqlite3
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from backend import Jira, UserError, memory_drafts


class IssueServer(Jira):
    def __init__(self):
        self.owner = "emir"
        self.title = "Eski başlık"
        self.status = {"id": "3", "name": "In Progress", "statusCategory": {"key": "indeterminate"}}
        self.comments = []

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
            return {"total": len(self.comments), "comments": self.comments}
        if path == "/issue/TASK-15/comment" and method == "POST":
            comment = {"id": str(len(self.comments) + 1), "body": body["body"]}
            self.comments.append(comment)
            return comment
        if path.startswith("/issue/TASK-15/comment/"):
            return self.comments[int(path.rsplit("/", 1)[-1]) - 1]
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
        self.assertEqual([c["body"]["content"][0]["content"][0]["text"] for c in jira.comments], [payload["text"]])


class MemoryTests(unittest.TestCase):
    def test_only_latest_verified_unambiguous_card_summary_is_proposed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory, "index.sqlite")
            with sqlite3.connect(path) as db:
                db.execute("CREATE TABLE notes(id, title, summary, status, verification, type, updated, created)")
                rows = [
                    (1, "TASK-150 farklı kart", "Yanlış hedef", "active", "verified", "note", "2026-11-18", ""),
                    (2, "TASK-15", "Doğrulanmadı", "active", "reported", "note", "2026-11-18", ""),
                    (3, "TASK-15", "Eski öneri", "active", "verified", "lesson", "2026-11-14", ""),
                    (4, "TASK-15", "Kurtarma senaryosu geçti.", "active", "verified", "lesson", "2026-11-16", ""),
                    (5, "TASK-15 ve TASK-16", "Karışık iş özeti", "active", "verified", "note", "2026-11-17", ""),
                    (6, "TASK-15", "Yürürlükten kalktı", "superseded", "verified", "note", "2026-11-18", ""),
                ]
                db.executemany("INSERT INTO notes VALUES (?, ?, ?, ?, ?, ?, ?, ?)", rows)
            db.close()
            issues = [{"key": "TASK-15", "id": "10015"}, {"key": "TASK-16", "id": "10016"}]
            drafts = memory_drafts(issues, {}, path)
            self.assertEqual([(d["key"], d["text"]) for d in drafts], [("TASK-15", "Kurtarma senaryosu geçti.")])
            self.assertEqual(memory_drafts(issues, {"TASK-15": drafts[0]["digest"]}, path), [])
