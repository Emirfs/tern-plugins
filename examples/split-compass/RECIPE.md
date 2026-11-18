# Split Compass

The active split's header gets a surface tint and an accent rule. The other panes stay at full brightness and their contents do not move.

```sh
tern plugin install github.com/Emirfs/tern-plugins/examples/split-compass
```

Open a split tab with pane headers visible, then move focus between panes. Only the header of the focused split should change. A solitary pane or a layout with headers hidden is deliberately unchanged.

To remove it: `tern plugin remove split-compass`.
