# omp-profile

Shows which [omp](https://github.com/can1357/oh-my-pi) profile the focused pane is running, so panes from
different profiles (`omp --profile work`, …) can be told apart.

- The tab title gets the profile as a prefix: `[work] ⟨session title⟩`.
- The status line gets an `omp: work` segment, colored per profile (`default` is muted). Turn the status
  line on with the `status_bar` action if it is hidden.

Panes that are not running omp are left alone.

## Install

```sh
tern plugin install github.com/Emirfs/tern-plugins/omp-profile
```

Requires Tern 0.9.5 or later. Window-only plugin: it adds no blocks.

## How it works

omp tells Tern which session file a pane is running (the `omp_session_file` user variable). The plugin
reads it for every pane with `tern inspect --json` and takes the profile from the path:
`~/.omp/profiles/<name>/…` is `<name>`, `~/.omp/agent/…` is `default`. It refreshes when focus moves, a
pane opens or closes, at most every 5 seconds on title changes, and every 30 seconds.

Tern's plugin API cannot change a split pane's own header, so the profile shows for the focused pane only.
