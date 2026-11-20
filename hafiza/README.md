# Memory vault

Tern panel for the shared memory vault (`~/GitHub/araclar/hafiza`, overridable with `HAFIZA_DIR`). Requires
Python 3; everything that writes to the vault goes through the vault's own `.tools/inbox.py`, the panel never
writes to the vault directly.

- The **Memory: suggestions and today** command opens the panel, or focuses it if it is already open.
- **Suggestions**: what agents leave with `memory_write op=propose` (summary, decision, lesson, profile, rule
  idea, open task). The selected suggestion shows its text, reason and source. **Accept** (`a`) applies the
  suggestion to its target note and commits; **Reject** (`x`) deletes the suggestion (it stays in git
  history). Right-click **Open target note** opens the note.
- Rule ideas do not go to the rule files automatically: if accepted they are written to `rules-accepted.md`
  in the vault, and you move them to agent-rules by hand.
- **Today**: the vault's `daily/<today>.md` note; the collector fills it every evening at 20:30.
- The panel refreshes every minute and on `r`.
