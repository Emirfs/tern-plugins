"""`tern-bridge read` against a temp spool: `python hermes-bridge/tests/test_cli.py` (stdlib only)."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

CLI = Path(__file__).resolve().parent.parent / "cli" / "tern_bridge.py"


class ReadTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.spool = self.root / "hermes-bridge" / "spool"

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def run_cli(self, *args: str, stdin: bytes = b"") -> subprocess.CompletedProcess:
        env = {**os.environ, "TERN_BRIDGE_SPOOL": str(self.spool), "PYTHONIOENCODING": "utf-8"}
        env.pop("TERN_BRIDGE_FROM", None)
        return subprocess.run([sys.executable, str(CLI), *args], input=stdin, capture_output=True, env=env)

    def jobs(self) -> list[dict]:
        return [json.loads(p.read_text(encoding="utf-8")) for p in sorted(self.spool.glob("*.json"))]

    def test_stdin_is_stored_under_reading(self) -> None:
        r = self.run_cli("read", "--title", "🧠 Café summary 19.11", "--key", "daily-2026-11-19",
                         "--from", "hafiza", "-", stdin="# Résumé\nhello\n".encode("utf-8"))
        self.assertEqual(r.returncode, 0, r.stderr)
        (job,) = self.jobs()
        self.assertEqual(
            {k: job[k] for k in ("v", "kind", "title", "key", "from")},
            {"v": 1, "kind": "read", "title": "🧠 Café summary 19.11", "key": "daily-2026-11-19", "from": "hafiza"},
        )
        path = Path(job["path"])
        self.assertEqual(path.parent, self.spool.parent / "reading")
        self.assertRegex(path.name, r"^\d{8}-\d{6}-café-summary-19-11\.md$")
        self.assertEqual(path.read_text(encoding="utf-8"), "# Résumé\nhello\n")

    def test_path_is_resolved(self) -> None:
        md = self.root / "note.md"
        md.write_text("x", encoding="utf-8")
        r = self.run_cli("read", "--title", "T", "--key", "k", str(md))
        self.assertEqual(r.returncode, 0, r.stderr)
        (job,) = self.jobs()
        self.assertEqual(job["path"], str(md.resolve()))
        self.assertEqual(job["from"], "cli")
        self.assertFalse((self.spool.parent / "reading").exists())

    def test_rejects(self) -> None:
        self.assertNotEqual(self.run_cli("read", "--title", "T", "--key", "k", str(self.root / "no.md")).returncode, 0)
        self.assertNotEqual(self.run_cli("read", "--title", "T", "--key", "k", "-", stdin=b"  \n").returncode, 0)
        big = b"x" * (200 * 1024 + 1)
        self.assertNotEqual(self.run_cli("read", "--title", "T", "--key", "k", "-", stdin=big).returncode, 0)
        self.assertNotEqual(self.run_cli("read", "--title", "x" * 121, "--key", "k", "-", stdin=b"x").returncode, 0)
        self.assertNotEqual(self.run_cli("read", "--title", "T", "--key", " ", "-", stdin=b"x").returncode, 0)
        self.assertEqual(self.jobs(), [])


if __name__ == "__main__":
    unittest.main()
