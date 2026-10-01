# UI rules: Personal tools

Open when: a tool only Michael uses, or a mock or review page for him (never a client product or KeepTheCall).
Rule format and principles: `FORMAT.md` in this folder. A rule's Touches line names a rule it interacts with and which wins.

### SOLO-01 Keycaps sit on their buttons
Applies: Action buttons that have keyboard shortcuts; desktop (keyboard + fine pointer)
Do: Show a button's shortcut as a keycap inside it, read from current bindings and the same on every item, never as hint text in bars.
Why: Hint lines crowd bars, and a key that changes per item gets pressed wrong.
Yes: `Trash ⌫` and `File 1` in an inbox bar, the same on every email · A Save button with a small S keycap
No: A header line reading `j/k move · Enter open · ? help`
Touches: UI-06. Compatible: drawing keycaps from the live binding is how key hints stay true.
Touches: SOLO-02. Compatible: SOLO-02 assigns one key per action and lists it in the ? sheet; Keycaps sit on their buttons sets how that key shows on its button.
Strength: invariant

### SOLO-02 One listed key per action
Applies: keyboard shortcuts in Michael's own tools; desktop
Do: Give every primary action, Back included, one key that stays the same wherever the action appears, and list every binding in the ? help sheet.
Why: A missing, per-page or undocumented key breaks muscle memory and leaves the action mouse-only.
Yes: n creates an item on every list page, and ? lists 'n New' · Backspace deletes in mail, tasks and calendar alike · The ? sheet on the mail page lists r Refresh and t Make task
No: a adds on the tasks page but b adds on the books page
Touches: APP-20. Compatible: Back's key is one of these bindings.
Touches: SOLO-01. Compatible: SOLO-02 assigns one key per action and lists it in the ? sheet; Keycaps sit on their buttons sets how that key shows on its button.
Strength: invariant

### SOLO-03 Bare-key motion within a region
Applies: Michael's own keyboard-driven tools; desktop, focus outside text fields
Do: h/l walk a horizontal strip, wrapping at its ends; j/k walk a vertical list across section breaks, skipping collapsed items; neither leaves the focused region.
Why: Bare keys that leave the region, or answer both axes, send focus somewhere the user did not aim.
Yes: Tab strip All · Unread · Starred: l on Starred lands on All · Mail list: j on the last Receipts row lands on the first Travel row, passing collapsed Promotions
No: j on the tab strip drops focus into the list below it
Touches: SOLO-04. Compatible: bare keys move inside a region; Ctrl chords move between regions.
Strength: invariant

### SOLO-04 Ctrl-chord jumps between regions
Applies: Michael's own keyboard-driven tools; desktop
Do: Ctrl+j/k jump between sections and regions, tab strip included; Ctrl+d/u move half a page; one Ctrl chord toggles nav and content focus, even inside editors.
Why: Without bigger jumps every trip is a j/k crawl or a reach for the mouse.
Yes: Ctrl+j in the inbox jumps from the Newsletters section to Receipts · Typing in a note, the nav key moves focus to the side nav
No: Ctrl+j lands inside a row's 1-4 option buttons
Touches: SOLO-03. Compatible: bare keys move inside a region; Ctrl chords move between regions.
Touches: SOLO-05. Compatible: SOLO-05 decides which chords are safe; this rule assigns the movement ones.
Strength: invariant

### SOLO-05 Safe keys for any-page actions
Applies: shortcuts for actions available from any page, in Michael's own tools; desktop
Do: Bind any-page actions to Ctrl chords (Ctrl, not Cmd, on Mac) free of OS, browser and in-app movement keys, never bare letters; Backspace only deletes.
Why: A colliding key fires the wrong action, and a different modifier per platform forces relearning.
Yes: Toggle assistant: Ctrl+Space on Mac and Windows · Open search: a Ctrl chord the vim layer leaves free
No: Search on Ctrl+K, which the vim layer already uses · Assistant on a bare a · Backspace opens the More menu on the calendar
Touches: SOLO-04. Compatible: SOLO-05 decides which chords are safe; SOLO-04 assigns the movement ones.
Strength: invariant

### SOLO-06 j/k stops on collapsed headers
Do: A collapsed section header takes focus; Space expands it; only its hidden rows are skipped.
Why: Q30, amending SOLO-03.

### SOLO-07 Ctrl chords win over browser chords
Do: SOLO-04's Ctrl+j/k/d/u are intercepted by the page, on Windows too.
Why: Q31.

### SOLO-08 The side nav starts collapsed
Do: In a personal tool the side nav starts collapsed; it remembers its state after that.
Why: Split from DESK-04 (Q7).
