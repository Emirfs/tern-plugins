# mods

Small switchable tweaks that restyle Tern, the way Claude Code mods personalize Claude Code: a settings
panel with an **Appearance** page and a **Mods** page, eleven built-in mods and a folder for your own CSS.
Every mod starts off; turn on what you like.

## Install

```sh
tern plugin install github.com/Emirfs/tern-plugins/mods
```

Tested on Tern 0.9.26 (Windows 11). The animated-image wallpaper needs `ffmpeg` and `ffprobe` on `PATH`.

## Usage

- Command palette: **Mods** (Turkish: **Modlar**) opens the panel beside the focused pane, or focuses it.
  Changes apply at once in every window.
- **Mods: toggle focus mode** (`Ctrl+Alt+Z`), **Mods: toggle privacy blur**, **Mods: turn every mod off**,
  **Mods: open the user mods folder**, **Mods: switch language (TR/EN)**.
- In the panel, `Esc` closes it and `l` switches the language.

## Appearance page

Only what Tern's own Settings don't have (font, size, theme, opacity, material, density and layout are
Tern's):

- **Language**: Turkish or English (saved as `lang`; until chosen, a `tr*` locale gives Turkish, anything
  else English; Windows sets none, so English).
- **Accent color**: replaces the theme's accent (selected tab, buttons, focus ring).
- **Corners**: sharp, soft or round corners for buttons, cards, menus and tabs.
- **Presets**: *Minimal* (compact tabs, tab style, pane shape), *Cozy* (tab style, pane shape, composer, busy
  animation), *Presenter* (privacy blur, focus mode). A preset replaces the set of mods that are on.
- **Turn every mod off**.

## Built-in mods

| Mod | What it does | Settings |
| --- | --- | --- |
| Compact tabs | Thinner tab bar; the panes move up. Horizontal tabs only. | bar height, text size, keep block shortcuts |
| Tab style | Pill, underline, block, outline or minimal tabs. | style, color, opacity of background tabs |
| Profile accent | Each omp profile gets a color on the tabs and panes running it. | edge / tint / both, tabs, panes, a color per profile (automatic: `default` none, others a fixed color from the name) |
| Focus mode | Hides the tab bar, window buttons and widget bar. | hide the status line, hide pane headers, peek (the bar shows at the top edge) |
| Privacy blur | Screen-recording mode: blurs tab titles, pane titles and paths, status lines, the omp-usage pane, account names; unblurs under the pointer. | strength, unblur on hover, each group |
| Pane shape | Gap between panes and corner radius. | gap, corners, hairline outline |
| Wallpaper | Animated gradient or an image (PNG, JPG, WebP, SVG; animated GIF/WebP play) behind the window. | gradient preset and loop length, image file and fit, dim, how panes sit over it (Tern / frosted / clear), bar shade |
| Composer | The bottom line of agent chats: input box, model/account row, status row above it. | density, corners, border, background, text size, status row show / dim / hide |
| Ask prompts | The agent's questions and approval requests: question box, permission dialog, waiting card. | border color, density, glow |
| Busy animation | Panes and tabs whose agent works: edge shimmer, tab pulse, both, or none (Tern's own animations go quiet too). | style, color, loop length |
| Parked chats | The pile of panes parked out of tabs. Its place and size stay Tern's (`park_pile`, drag a card). | cards Tern / compact / large preview, idle opacity, accent stripe |

Limits, stated honestly:

- **Privacy blur** blurs fixed places. CSS can't find an e-mail or a token inside text: what a terminal or a
  chat prints stays readable.
- **Profile accent** reads each pane's omp session file from `tern inspect --json` (as `omp-profile` does).
  Tabs are found by the pane id on their program icon; panes on the stage carry no id, so a pane is found by
  its header's title and only colors while its header shows. The focused pane's border and header may be
  drawn over by other plugins (pane-highlight).
- **Busy animation**: Tern marks a working tab (`.tt.working`) and a terminal running a command
  (`.tn-pane.working`), but not a working omp pane; that one is found by the *Running* dot in its header, so
  only while the header shows.
- **Wallpaper**: Tern draws only the first frame of an animated GIF/WebP in CSS, so the host half converts it
  with ffmpeg into one sprite sheet (at most 48 frames, 12 fps, 4096 px a side) in the plugin's data folder,
  played with CSS keyframes. Video files can't play. The approach (picture on `body`, `main#panel` made
  transparent, sprite sheet frames) follows [tern-backdrop](https://github.com/avcton/tern-backdrop) (MIT);
  no code is copied.

## Your own mods

Every `*.css` file in `<plugin data>/user-mods/` (on Windows
`%LOCALAPPDATA%\Tern\plugin-data\mods\user-mods`) shows up on the Mods page under *Your mods*, off by
default. A leading comment names it:

```css
/* title: Neon tabs */
#tabbar .tt.on { box-shadow: 0 0 12px var(--accent) !important; }
```

Without it the file name is the title. The CSS is applied as is; edits show within two seconds.

## How it works

Settings live in the plugin's `tern.kv` (`on`, `cfg`, `look`, `lang`), shared by both halves and every
window. The host half (`host.luau`) draws the panel with Tern's native settings page (`prefs` node) and
converts animated wallpapers. The window half (`window.luau`) reads kv every 500 ms (a cheap read; Tern
reloads the file only when it changed) and installs each mod as its own sheet with `tern.css("mod-<id>", …)`
(sheet names allow letters, digits, `_` and `-`, so `mod-` rather than `mod:`), only when its CSS changed;
a mod turned off gets an empty sheet. Every value from kv is validated (`lib/schema.luau`) before it reaches
CSS: unknown choices, out-of-range numbers and anything that isn't a palette name or a hex color fall back
to the default.

Layout: `lib/mods/*.luau` (one module per mod: defaults, fields, `css(settings, env)`), `lib/registry.luau`
(the list, kv keys, user mods), `lib/panel.luau` (panel rows and how a change becomes kv writes),
`lib/appearance.luau`, `lib/schema.luau`, `lib/sprite.luau`, `lib/i18n.luau`.

## Fragility

The mods target Tern's internal classes and omp's surface roles (`#tabbar`, `.tt`, `.tn-pane`, `.tn-head`,
`--tn-bar`, `--tn-tile-gap`, `.pk-pile`, `[data-role='omp.editor']`, …). They were checked against
Tern 0.9.26; a Tern update that renames them breaks the mod that uses them until it is updated.

## Tests

From the repository root, with [lune](https://github.com/lune-org/lune):

```sh
lune run mods/tests/run.luau
```

They cover settings validation, the CSS every mod generates for each of its choices, the panel's
change handling, user mod naming and the sprite sheet plan.
