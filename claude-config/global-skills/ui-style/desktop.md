# UI style: Desktop

Open when: anything used on a desktop or laptop screen.
Rule format and principles: `FORMAT.md` in this folder. A rule's Touches line names a rule it interacts with and which wins.

### DESK-01 Keyboard reach of every control
Applies: every region and control on every page; desktop, any product
Do: Make every region and control reachable from the keyboard, with Enter or Space activating whatever has focus, still working after the window regains focus.
Why: Anything only a mouse can reach strands a keyboard user mid-task.
Yes: The date picker, the header's Filter button and the image carousel each take focus and respond to Enter · Space on a focused, collapsed 'Done' header expands it
No: The top tab strip responds to clicks, but no key reaches it · Enter on a focused tab fires the page's own Enter shortcut instead
Strength: invariant

### DESK-02 One visible keyboard focus
Applies: keyboard focus on every page; desktop, any product
Do: Keep one focus highlight, shown instantly after any move or refocus, kept on screen; reversing a move or closing a modal or menu restores it.
Why: An invisible, doubled or dropped focus leaves the user unsure where the next key goes.
Yes: Back in the browser after Cmd+Tab: the focused row is already highlighted · Tab from a Save button into the list unhighlights Save; Shift+Tab lands on Save again · Esc closes an event dialog; focus is on that event and ↓ moves to the next
No: Save and the first list row highlighted at the same time
Touches: APP-08. Compatible: APP-08 keeps scroll and selection across views; this keeps the focus visible within one.
Strength: invariant

### DESK-03 Side-by-side panes when there is room
Applies: Supporting panes (notes, preview, details); desktop windows wide enough for two
Do: Prefer opening supporting content as its own pane beside the main one when the window has room, each pane toggling and resizing on its own.
Why: Switching back and forth between views loses the user's place in both.
Yes: An email thread with the sender's details in a slim pane beside it, split by a draggable divider
Touches: COMP-03. Compatible: One area per screen shows one app area at a time; DESK-03 lays out that area's supporting panes beside its main pane.
Strength: default

### DESK-04 Side panels resize and remember
Applies: Side nav and docked panels; desktop
Do: Let side panels collapse and resize by dragging their inner edge, keeping each one's open state and width across pages and reloads.
Why: A panel that reopens or resets on every page has to be fixed by hand each time.
Yes: Close the help panel, change pages: it stays closed · Drag the chat panel from 360px to 520px; it reopens at 520px
No: The side nav snapping back to its default width after a reload
Touches: TOUCH-05. Compatible: device split; this rule is desktop, TOUCH-05 is touch.
Touches: COMP-12. Compatible: a collapsed side nav still sits on every page behind its toggle; DESK-04 sets its default state, COMP-12 its contents.
Strength: default

### DESK-05 Drop files anywhere on the page
Applies: Pages and editors that accept files or photos; desktop (keyboard + fine pointer)
Do: Accept files dropped anywhere on the page, not only on a drop zone, and let the file dialog pick several at once.
Why: A small fixed drop zone makes attaching fiddly.
Yes: Dragging a PDF onto any part of an expense form attaches it
No: Drops accepted only inside a dashed box at the page foot
Strength: invariant

### DESK-06 Shortcut hints only in all-day tools
Applies: Keycaps on buttons and a ? shortcut sheet; desktop
Do: Show keycaps and a ? shortcut sheet only in tools someone works in all day at a desk, never on public or client websites.
Why: Occasional visitors never learn shortcuts, and keycaps clutter their buttons.
Yes: A support agent's ticket queue with a ? sheet · A restaurant's site with no key hints
Strength: invariant
