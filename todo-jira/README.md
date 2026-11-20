# Todo · Jira

Uses Tern's existing `~/TODO.md` board; it does not create a separate list or a copy of Jira.
Requires Python 3. Install with `tern plugin link <clone>/todo-jira`. Write
`{"jira_url":"https://<site>.atlassian.net"}` into `config.json` in the plugin's data directory, or
set `TERN_JIRA_URL`. The Jira e-mail and API token are read from `~/.jira_token.txt`, on two
separate lines in that order (override the path with `TERN_JIRA_CREDENTIAL_FILE`). The token is
never put in the plugin settings, the command line or a preview. `TERN_TODO_PATH` selects a
different local Markdown board.

- **Jira pane (cards and comments)**: shows the cards assigned to this account and every comment on
  each card (author, date, Markdown text; your own comments are marked "you", newest first) in a
  separate pane. It is read-only and refreshes every five minutes and on `r`; `d` shows finished
  cards, and `enter` or a double click opens the card in Jira. Right-click a row for **Hand to AI**
  (opens the Kanban flow below with that card), **Open in Jira**, **Copy link** and **Open memory
  note**.
- **Refresh from Jira**: puts the cards assigned to the linked account into the `Todo`, `Doing` and
  `Done` columns. Afterwards the main window reads Jira every five minutes and applies later
  changes to the board; if this background sync stops, the error is reported once.
- **Changes**: for a title, due date or status that changed on the board, shows the target and the
  value. For a status, pick the transition Jira currently allows. Every field is written only with
  **Send to Jira**. Fields changed on both sides are not overwritten; to resolve one, set the
  field on the board to the reported Jira value and redo the edit if needed. Order within a column,
  local labels and notes are not sent to Jira. Deleting a card locally does not delete the Jira
  card; local notes of a card that falls out of the assignment scope are left untouched.
- **Assign to AI / Add to Kanban**: pick a local or linked TODO card (or right-click **Hand to AI**
  in the Jira pane) and optionally an AI profile; with a single Hermes board the board is not
  asked. For a Jira card the task gets the card's Jira description and its last three comments.
  Hermes runs an approved assignment itself; a card without an assignee is only added to the board.
  For the same card, profile and context Hermes does not open a new task but returns the existing
  one; the notification reports that task's status.
- **Memory vault**: on every sync a `jira/<KEY>.md` note is kept for each assigned card in the
  shared memory vault (default `~/GitHub/araclar/hafiza`; `vault` in `config.json` or
  `TERN_HAFIZA_DIR`). The plugin rewrites only the frontmatter and the **Sent to Jira** section
  (your Jira comments) from Jira; the Summary, Log, Open, Decisions and Jira draft sections belong
  to you and your agents and are never touched. If the vault is a git repository, changed notes are
  saved in a single commit. The Jira pane shows a card's filled sections; right-click **Open memory
  note** opens the file.
- **Changes** and **Fill**: when the note's **Jira draft** section is filled, that text (Markdown)
  is offered as the card's progress comment. **Fill · Send this text to Jira** adds it to Jira after
  approval; it does not change the description or the status, and it does not send the text again
  if the same text is already there. The sent draft is cleared in the note and moves to the **Sent
  to Jira** list. Telling Carly **fill** also opens the preview; nothing is written without your
  approval in the picker.

Verification without writing to live Jira or Hermes: `python -B -m unittest discover -s todo-jira/tests`.
