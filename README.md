# tern-plugins

Plugins for [Tern](https://docs.stencil.so/tern/), one installable folder each.

| Plugin | What it does |
| --- | --- |
| [omp-usage](omp-usage) | Remaining usage limits of every account across all omp profiles, in one pane |
| [omp-profile](omp-profile) | The omp profile each pane runs, in every split's header (with its omp extension), the tab title and the status line |
| [split-columns](split-columns) | Turns a grid of split rows into columns, so each column's divider moves on its own |

omp extension (no Tern half; installed through omp's `config.yml`, see its README):

| Extension | What it does |
| --- | --- |
| [omp-account](omp-account) | `/hesap`: which OAuth account of the model's provider this conversation uses, shown in the status line |

## Install

```sh
tern plugin install github.com/Emirfs/tern-plugins/<plugin>
```

To work on a clone in place, link a plugin folder instead: `tern plugin link <clone>/<plugin>`. Tern reloads
a linked plugin when its files change.

Type-check a plugin against the API your Tern ships with, and run its tests. The tools are pinned in
`rokit.toml` (`rokit install`), or take [luau-lsp](https://github.com/JohnnyMorganz/luau-lsp/releases) and
[lune](https://github.com/lune-org/lune/releases) releases:

```sh
tern plugin types .
luau-lsp analyze --platform=standard --definitions=@tern=tern.d.luau <plugin>/*.luau <plugin>/lib/*.luau
lune run <plugin>/tests/run.luau   # omp-usage, split-columns
```

## License

MIT
