# hermes-bridge

Bridge between Carly, Hermes and omp (window half only, `window.luau`).

## What it gives Carly (`plugins['hermes-bridge']`)

| Export | What it does |
| --- | --- |
| `hermes_ask(prompt, profile?)` | `hermes [-p profile] -z prompt`, returns the final answer text (≤ 2 min) |
| `hermes_kanban(title, body?, assignee?)` | `hermes kanban create --json --created-by carly …`; Hermes sends the notifications from its own hub |
| `esp_list()` | `hermes tern --list-devices` (C1) |
| `esp_open(device)` | Opens or focuses the device's tab in the "ESP" session (`hermes tern --device <id>`, tab name = device name) |
| `omp_start(prompt, cwd?, command?)` | `cx.agents:start{how='tab'}` |
| `agents_list()` | Summary of `cx.agents:list()` |

Context line (`tern.carly.context`, ≤ 400 characters): platform states from `gateway_state.json` and the
device list. The provider only returns ready-made text (4 ms budget); a timer refreshes the text every
minute, and the leader window fetches the device list every 5 minutes with `hermes tern --list-devices`
(`tern.kv` `devices`).

## The `tern-bridge` queue

`tern-bridge` (Python stdlib) writes `%LOCALAPPDATA%\Tern\plugin-data\hermes-bridge\spool\<id>.json`
(first `.tmp`, then a rename; `TERN_BRIDGE_SPOOL` overrides the location). A single window (kv `leader`
heartbeat) picks up jobs every 2 s: it deletes the file, runs the job, and writes the outcome under `done/`
or `failed/` (with the reason); each keeps at most 200 records.

```
tern-bridge carly TEXT...                 # cx:ask_carly
tern-bridge omp [--cwd DIR] [--command C] [--how tab|split|replace_if_alone] PROMPT...
tern-bridge esp DEVICE                    # esp_open
tern-bridge notify [--level info|success|error] [--title T] TEXT...   # toast
tern-bridge read --title T --key KEY [--from NAME] (PATH | -)          # reading tab
tern-bridge status [--json]               # pending / failed / recent jobs
```

`-` reads the text from stdin, `--from NAME` records the sender, `--wait N` waits for the outcome (exit 0
done, 1 failed, 2 still pending: Tern or the plugin is not running).

`read`: opens a Markdown file as a new blue tab in the session the user is currently looking at (tab name
`T`) and shows a short info toast; closing the tab = read. `-` writes stdin (≤ 200 KB) to
`plugin-data\hermes-bridge\reading\<YYYYMMDD-HHMMSS>-<slug>.md` (a sibling of the spool), and the job carries
that path; PATH must also be ≤ 200 KB. The same `KEY` is opened once (kv `read_seen`, last 500 keys; a
repeat lands under `done/` with `duplicate = true`). `cx.docs:open` has no focus option: after opening, the
user's focused pane is put back, and the tab waits in the tab bar. Producers: the Hermes cron
`hafiza_collect.py` (`daily-<date>` once the daily note is written and settled), device agents, memory
suggestions, kanban.

Install: `cli\install.cmd` → `%USERPROFILE%\.local\bin\tern-bridge.cmd` + `tern_bridge.py`
(on the user's PATH).

Skills: for Hermes `%LOCALAPPDATA%\hermes\skills\autonomous-ai-agents\tern-bridge\SKILL.md`, for omp
(all profiles, `agents:user` source) `~\.agents\skills\tern-bridge\SKILL.md`. Both forbid jobs that write to
a device and sending messages on the user's behalf without explicit approval.

## Tests

```sh
lune run hermes-bridge/tests/run.luau
python hermes-bridge/tests/test_cli.py
luau-lsp analyze --platform=standard --definitions=@tern=tern.d.luau hermes-bridge/*.luau hermes-bridge/lib/*.luau
```

`tests/window_stub.luau` runs `window.luau` without Tern (exports, queue, leader, ESP tab).
