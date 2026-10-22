# tern-omp-usage

A [Tern](https://docs.stencil.so/tern/) plugin that shows the remaining usage limits of every account
across all of your [omp](https://github.com/can1357/oh-my-pi) profiles (`default` and
`~/.omp/profiles/*`) in a single pane. An account signed in to several profiles is counted once.

```
Hesap                     5 saat        ↻   7 gün        ↻
Claude 2 hesap              %85   Σ 1.7/2     %26   Σ 0.5/2
› ali                       %86   4sa33dk     %36    1g10sa
› ayse · Acme               %85   4sa23dk     %16   2sa33dk
Codex ali · plus           %100   4sa58dk     %72    4g19sa
Antigravity ali             %94   1sa42dk     %95    3g21sa
3 profil · 14:26 · r yenile · R önbelleksiz
```

The pane's labels are in Turkish (`5 saat` = 5 hours, `7 gün` = 7 days, `hesap` = account,
`sa`/`dk`/`g` = hours/minutes/days).

## Install

```sh
tern plugin install github.com/Emirfs/tern-omp-usage
```

To work on a clone in place: `tern plugin link <clone-dir>`.

Requires Tern 0.9.5 or later, and the `omp` CLI on the machine that runs your panes.

## Usage

- Command palette (`Ctrl+Shift+P`): **omp kullanımını aç (tüm hesaplar)** opens the pane beside the
  focused one, or focuses it if this window already has one. The palette's **New omp kullanım block**
  row opens the same pane.
- Key bind: `Ctrl+Alt+Shift+U`.
- `r` refreshes; `R` clears omp's usage cache (`omp usage invalidate`) and then refreshes. Data refreshes
  on its own every 2 minutes; reset countdowns update every 30 seconds.

## What it shows

- Each column is a limit window (5 hours, 7 days; limits with their own quota pool get their own
  column). A cell is the remaining percentage of the account's most-used limit in that window, the same
  rule omp's `capacity` uses.
- For a provider with several accounts, the top row is the total: the average remaining percentage and
  `Σ remaining/accounts` (`Σ 1.7/2`: the two accounts have 1.7 accounts' worth of quota left).
- Below 20% shows yellow, an exhausted limit red. `↺N` marks the usage-limit resets an account can still
  redeem.
- A `⚠` line under the table reports a profile that could not be read or an account that was disabled.

The pane fits its size so it never needs scrolling: as it narrows, the bars go first, then the reset
columns, then the e-mail addresses, and the narrowest panes switch to a list. In a short pane, providers
with several accounts collapse to their total row.

## How it works

The plugin's host half runs `omp [--profile <name>] usage --json` for each profile (with `OMP_PROFILE`
set, plus `PI_CODING_AGENT_DIR` for the default profile), deduplicates accounts by provider and
e-mail/organization, and keeps the freshest report of each account. `omp` is looked up on `PATH` first,
then at `%LOCALAPPDATA%\Tern\omp\bin\omp.exe` and `~/.bun/bin/omp`.

## License

MIT
