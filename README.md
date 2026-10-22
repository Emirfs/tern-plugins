# tern-plugins

Plugins for [Tern](https://docs.stencil.so/tern/), one installable folder each.

| Plugin | What it does |
| --- | --- |
| [omp-usage](omp-usage) | Remaining usage limits of every account across all omp profiles, in one pane |
| [omp-profile](omp-profile) | The omp profile each pane runs, in every split's header (with its omp extension), the tab title and the status line |

## Install

```sh
tern plugin install github.com/Emirfs/tern-plugins/<plugin>
```

To work on a clone in place, link a plugin folder instead: `tern plugin link <clone>/<plugin>`. Tern reloads
a linked plugin when its files change.

Type-check a plugin against the API your Tern ships with
[luau-lsp](https://github.com/JohnnyMorganz/luau-lsp/releases):

```sh
tern plugin types .
luau-lsp analyze --definitions=tern.d.luau <plugin>/*.luau
```

## License

MIT
