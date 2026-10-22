# omp-profile

Shows which [omp](https://github.com/can1357/oh-my-pi) profile each Tern pane is running, so panes from
different profiles (`omp --profile work`, …) can be told apart. Two parts:

| Part | Shows | Where it runs |
| --- | --- | --- |
| `omp-extension/profile-title.ts` | `[work] ⟨session title⟩` as the pane's title: every split's header and the tab | omp, in each profile |
| The Tern plugin (`plugin.toml`, `window.luau`) | `omp: work` in the status line; the `[work]` tab prefix when the extension is not installed | Tern |

## Install

The omp extension: add it to each profile's `config.yml` (`~/.omp/agent/config.yml` for `default`,
`~/.omp/profiles/<name>/agent/config.yml` for the others):

```yaml
extensions:
  - <clone>/omp-profile/omp-extension/profile-title.ts
```

omp sessions started after that show the profile; restart omp in panes that were already running. The
extension does nothing outside Tern (`TERM_PROGRAM` other than `tern`).

The Tern plugin:

```sh
tern plugin install github.com/Emirfs/tern-plugins/omp-profile
```

Requires Tern 0.9.5 or later. Window-only plugin: it adds no blocks. Turn the status line on with the
`status_bar` action if it is hidden.

## How it works

omp owns a pane's title. The extension sets it to `[<profile>] <session title>` through omp's `setTitle`;
omp drops an extension title whenever it sets the session title (first reply, `/rename`, session switch),
so the extension applies it again on session and turn events and every two seconds. The profile comes from
the session file's path, else `OMP_PROFILE` / `PI_PROFILE`.

The Tern plugin reads the session file omp reports to Tern for every pane (`omp_session_file` in
`tern inspect --json`) and takes the profile from its path: `~/.omp/profiles/<name>/…` is `<name>`,
`~/.omp/agent/…` is `default`. It refreshes when focus moves, a pane opens or closes, at most every 5
seconds on title changes, and every 30 seconds. Tern's plugin API cannot change a split's header, which is
why the per-pane label comes from the omp extension.
