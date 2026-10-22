# split-columns

Makes each column of a split grid resize on its own: dragging the divider in the right column no longer
moves the one in the left column.

Tern keeps splits as a binary tree. A 2×2 grid built row by row, `(A | B) / (C | D)`, has one horizontal
divider that cuts across both columns, so raising it on the right raises it on the left too. Built column
by column, `(A / C) | (B / D)`, every column gets its own horizontal divider:

```
Before                     After
┌──────┬──────┐            ┌──────┬──────┐
│  A   │  B   │            │  A   │  B   │
├──────┼──────┤  ───────▶  │      ├──────┤
│  C   │  D   │            ├──────┤  D   │
└──────┴──────┘            │  C   │      │
                           └──────┴──────┘
```

The plugin finds every grid of rows in a tab (at least 2 rows, every row with the same number of panes, at
least 2), also when it is only part of the tab, for example the right half beside a full-height pane, and
turns it into the same panes in columns by moving them; programs keep running. The columns then share the
vertical dividers, as a tiling layout must.

## Usage

- Automatic: when the plugin loads (for the tab on screen), when you switch to a pane or tab, and after you
  split or close a pane in this window.
- Command palette: **Izgarayı sütunlara ayır** does it for the current tab.
- **Bağımsız sütunlar: otomatik çevirmeyi aç/kapat** turns the automatic conversion off or on (saved).

If a move fails half way, the tab's layout is restored. Zoomed tabs are left alone.

## Install

```sh
tern plugin install github.com/Emirfs/tern-plugins/split-columns
```

Requires Tern 0.9.5 or later. Window-only plugin.
