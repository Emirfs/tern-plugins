#!/usr/bin/env python3
"""tern-bridge: hand work to Tern from Hermes, omp or a shell.

Writes one JSON job per call into the spool the Tern plugin `hermes-bridge` consumes (the plugin's
leader window polls it every 2 s and moves each job to done/ or failed/ with the outcome):

  tern-bridge carly TEXT...                 ask Carly (Tern's assistant) in the Tern window
  tern-bridge omp [--cwd DIR] PROMPT...     start an omp agent tab with PROMPT
  tern-bridge esp DEVICE                    open/focus the ESP device's live Hermes tab
  tern-bridge notify [--level L] TEXT...    show a toast in Tern
  tern-bridge read --title T --key K (PATH | -)   open Markdown as a new tab of the session shown in Tern
  tern-bridge status [--json]               pending, failed and recent jobs

A text/prompt of `-` is read from stdin (use it for long or multi-line prompts). `--wait SECONDS`
waits for the plugin to take the job and prints its outcome. Stdlib only.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import sys
import time
from pathlib import Path

READ_MAX_BYTES = 200 * 1024
# Limits the plugin's validation enforces (bridge.luau LIMITS).
TITLE_MAX = 120
KEY_MAX = 200

VERSION = 1
PLUGIN_ID = "hermes-bridge"


def spool_dir() -> Path:
    env = os.environ.get("TERN_BRIDGE_SPOOL")
    if env:
        return Path(env)
    base = os.environ.get("LOCALAPPDATA")
    if base:
        return Path(base) / "Tern" / "plugin-data" / PLUGIN_ID / "spool"
    return Path.home() / ".local" / "share" / "Tern" / "plugin-data" / PLUGIN_ID / "spool"


def new_id() -> str:
    now = time.time()
    stamp = time.strftime("%Y%m%dT%H%M%S", time.gmtime(now))
    return f"{stamp}-{int(now * 1000) % 1000:03d}-{secrets.token_hex(3)}"


def write_atomic(path: Path, data: dict) -> None:
    tmp = path.with_name(f".{path.stem}.tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(tmp, path)


def reading_dir() -> Path:
    """Stdin Markdown for `read` lands beside the spool: <plugin-data>/hermes-bridge/reading."""
    return spool_dir().parent / "reading"


def slug(title: str) -> str:
    s = re.sub(r"[^\w]+", "-", title.lower(), flags=re.UNICODE).strip("-_")
    return s[:40].strip("-_") or "note"


def store_reading(text: str, title: str) -> Path:
    directory = reading_dir()
    directory.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    path = directory / f"{stamp}-{slug(title)}.md"
    n = 1
    while path.exists():
        n += 1
        path = directory / f"{stamp}-{slug(title)}-{n}.md"
    path.write_text(text, encoding="utf-8")
    return path


def read_job(parser: argparse.ArgumentParser, source: str, title: str, key: str) -> dict:
    title, key = title.strip(), key.strip()
    if not title or len(title.encode("utf-8")) > TITLE_MAX:
        parser.error(f"--title must be 1-{TITLE_MAX} bytes")
    if not key or len(key.encode("utf-8")) > KEY_MAX:
        parser.error(f"--key must be 1-{KEY_MAX} bytes")
    if source == "-":
        data = sys.stdin.buffer.read(READ_MAX_BYTES + 1)
        if len(data) > READ_MAX_BYTES:
            parser.error(f"stdin is larger than {READ_MAX_BYTES // 1024} KB")
        text = data.decode("utf-8", errors="replace")
        if not text.strip():
            parser.error("stdin is empty")
        path = store_reading(text, title)
    else:
        path = Path(source).expanduser().resolve()
        if not path.is_file():
            parser.error(f"no such file: {path}")
        if path.stat().st_size > READ_MAX_BYTES:
            parser.error(f"{path} is larger than {READ_MAX_BYTES // 1024} KB")
    return {"kind": "read", "path": str(path), "title": title, "key": key}


def text_arg(parts: list[str]) -> str:
    if parts == ["-"]:
        return sys.stdin.read()
    return " ".join(parts)


def submit(job: dict, wait: float) -> int:
    spool = spool_dir()
    spool.mkdir(parents=True, exist_ok=True)
    job = {"v": VERSION, "id": new_id(), "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), **job}
    job = {k: v for k, v in job.items() if v not in (None, "")}
    name = f"{job['id']}.json"
    write_atomic(spool / name, job)
    print(f"queued {job['kind']} {job['id']}")
    if wait <= 0:
        return 0
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        for sub, code in (("done", 0), ("failed", 1)):
            rec = read_json(spool / sub / name)
            if rec is not None:
                if code == 0:
                    print(f"done: {json.dumps(rec.get('result'), ensure_ascii=False)}")
                else:
                    print(f"failed: {rec.get('error')}")
                return code
        time.sleep(0.5)
    print(
        f"still pending after {wait:g}s: is Tern running with the {PLUGIN_ID} plugin? "
        f"(the job stays queued and runs when it starts)"
    )
    return 2


def read_json(path: Path) -> dict | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def age(path: Path) -> str:
    try:
        secs = max(0, int(time.time() - path.stat().st_mtime))
    except OSError:
        return "?"
    if secs < 120:
        return f"{secs}s"
    if secs < 7200:
        return f"{secs // 60}m"
    return f"{secs // 3600}h"


def jobs_in(directory: Path) -> list[Path]:
    try:
        return sorted(p for p in directory.iterdir() if p.suffix == ".json" and not p.name.startswith("."))
    except OSError:
        return []


def status(as_json: bool, limit: int) -> int:
    spool = spool_dir()
    pending = []
    for p in jobs_in(spool):
        job = read_json(p) or {}
        pending.append({"id": p.stem, "kind": job.get("kind"), "age": age(p)})
    failed = []
    for p in jobs_in(spool / "failed")[-limit:]:
        rec = read_json(p) or {}
        job = rec.get("job") if isinstance(rec.get("job"), dict) else {}
        failed.append({"id": p.stem, "kind": job.get("kind"), "error": rec.get("error"), "at": rec.get("processed_at")})
    done = jobs_in(spool / "done")
    recent = []
    for p in done[-limit:]:
        rec = read_json(p) or {}
        job = rec.get("job") if isinstance(rec.get("job"), dict) else {}
        recent.append({"id": p.stem, "kind": job.get("kind"), "result": rec.get("result"), "at": rec.get("processed_at")})
    if as_json:
        print(json.dumps({"spool": str(spool), "pending": pending, "failed": failed, "done": recent,
                          "done_total": len(done)}, ensure_ascii=False, indent=1))
        return 0
    print(f"spool: {spool}")
    print(f"pending ({len(pending)}):" + ("" if pending else " none"))
    for j in pending:
        print(f"  {j['id']}  {j['kind']}  queued {j['age']} ago")
    if pending and any(a["age"].endswith(("m", "h")) for a in pending):
        print("  ! jobs older than 2 minutes: Tern or the hermes-bridge plugin is probably not running")
    print(f"failed (last {limit}):" + ("" if failed else " none"))
    for j in failed:
        print(f"  {j['id']}  {j['kind']}  {j['error']}")
    print(f"done: {len(done)} kept")
    for j in recent:
        print(f"  {j['id']}  {j['kind']}  {json.dumps(j['result'], ensure_ascii=False)}")
    return 0


def main(argv: list[str] | None = None) -> int:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[attr-defined]
        except (AttributeError, ValueError):
            pass

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--from", dest="sender", default=os.environ.get("TERN_BRIDGE_FROM", "cli"),
                        help="who sends the job (hermes, omp, …; default $TERN_BRIDGE_FROM or cli)")
    common.add_argument("--wait", type=float, default=0, metavar="SECONDS",
                        help="wait for the plugin to run the job and print its outcome")

    parser = argparse.ArgumentParser(prog="tern-bridge", description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("carly", parents=[common], help="ask Carly in the Tern window")
    p.add_argument("text", nargs="+", help="the question or request (- reads stdin)")

    p = sub.add_parser("omp", parents=[common], help="start an omp agent tab with a prompt")
    p.add_argument("--cwd", default=None, help="working directory (default: the current one)")
    p.add_argument("--command", default=None,
                   help="agent command instead of Tern's agent setting, e.g. \"omp --profile work\"")
    p.add_argument("--how", choices=["tab", "split", "replace_if_alone"], default="tab")
    p.add_argument("prompt", nargs="+", help="the first prompt (- reads stdin)")

    p = sub.add_parser("esp", parents=[common], help="open/focus an ESP device's live Hermes tab")
    p.add_argument("device", help="device id (fa-…), alias or part of its name")

    p = sub.add_parser("notify", parents=[common], help="show a toast in Tern")
    p.add_argument("--level", choices=["info", "success", "error"], default="info")
    p.add_argument("--title", default=None, help="secondary line")
    p.add_argument("text", nargs="+", help="the message (- reads stdin)")

    p = sub.add_parser("read", parents=[common], help="open Markdown as a new tab of the session shown in Tern")
    p.add_argument("--title", required=True, help=f"tab title (<= {TITLE_MAX} bytes)")
    p.add_argument("--key", required=True, help="dedupe key: a key opened once is not opened again")
    p.add_argument("source", help="Markdown file, or - for stdin (stored under reading/)")

    p = sub.add_parser("status", help="pending, failed and recent jobs")
    p.add_argument("--json", action="store_true")
    p.add_argument("--limit", type=int, default=5)

    args = parser.parse_args(argv)
    if args.cmd == "status":
        return status(args.json, max(1, args.limit))

    if args.cmd == "carly":
        job = {"kind": "carly", "text": text_arg(args.text)}
    elif args.cmd == "omp":
        cwd = os.path.abspath(args.cwd) if args.cwd else os.getcwd()
        job = {"kind": "omp", "prompt": text_arg(args.prompt), "cwd": cwd, "command": args.command, "how": args.how}
    elif args.cmd == "esp":
        job = {"kind": "esp_open", "device": args.device}
    elif args.cmd == "read":
        job = read_job(parser, args.source, args.title, args.key)
    else:
        job = {"kind": "notify", "text": text_arg(args.text), "level": args.level, "title": args.title}
    for key in ("text", "prompt"):
        if key in job and not job[key].strip():
            parser.error(f"{key} is empty")
    job["from"] = args.sender
    return submit(job, args.wait)


if __name__ == "__main__":
    sys.exit(main())
