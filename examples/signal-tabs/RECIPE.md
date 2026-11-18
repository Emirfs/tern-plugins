# Signal Tabs

A steady line under the tab title distinguishes work in progress (dotted), a request for attention (dashed), and a failure (solid). Failure wins over waiting, and waiting wins over working. Native tab badges, tab selection and keyboard focus remain visible.

```sh
tern plugin install github.com/Emirfs/tern-plugins/examples/signal-tabs
```

Open several tabs with running work, a pane waiting for you, and a failed pane. Look for the underline under each title. An idle title is unchanged; the mod does not create or clear alerts. It uses Tern's `.working` and per-pane `data-st` markers, not an agent-specific hook.

To remove it: `tern plugin remove signal-tabs`.
