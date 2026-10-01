# UI rules: Core

Open when: building or changing any app with more than one screen.
Rule format and principles: `FORMAT.md` in this folder. A rule's Touches line names a rule it interacts with and which wins.

### APP-01 Actions hold fixed slots
Applies: Action bars, button rows and step navigation, across item types and pages; all devices
Do: Give each action one slot, order and style wherever it appears, Previous far left, Next far right; unavailable ones hold their slot, greyed or blank.
Why: Actions that move between items or around a missing neighbor cause mis-taps.
Yes: Delete in the same bar slot on an invoice, a receipt and a quote · On the first photo, a greyed ‹ at the far left and an active › at the far right
No: Next sliding left into Previous's place on the first step
Touches: UI-15. Compatible: a greyed control holding its slot (Actions hold fixed slots) is visibly unavailable; Every enabled control works bans controls that look usable and do nothing.
Touches: UI-23. Compatible: Primary right, leave actions left sets a row's order; Actions hold fixed slots keeps that order identical everywhere and holds slots.
Strength: invariant

### APP-02 Centered on its anchor
Applies: Glyphs in buttons, markers, side blocks, bar titles and focal elements; all devices
Do: Center each glyph, marker, row-side block, bar title on its whole parent box; glyphs span at least half their button, bar buttons the bar's height.
Why: An element a few pixels off center reads as sloppy even when nobody can say why.
Yes: A close × filling about half its square button, centered on both axes · A day-number block centered on its whole three-line event row
No: A small × sitting above center in a large button · A day-number block aligned to the first line of a three-line event row
Touches: COMP-24. Compatible: the × sits top-right and fills and centers in its square button.
Strength: invariant

### APP-03 Uniform siblings
Applies: repeated items: bar buttons, list rows, cards, grid tiles, table columns; all devices
Do: Give siblings one height, grid columns one width, optional fields fixed slots, and choose a column count that fills every row of a fixed set.
Why: Rows and tiles that change shape with their content look ragged and cannot be compared at a glance.
Yes: Reply, Forward and Add to calendar buttons all 56px tall although one label is longer · Order rows keep one height and a one-line title whether or not a tracking number exists; four summary cards sit 2 by 2
No: Four cards in three columns, leaving one alone on the last row
Touches: UI-19. APP-03 wins for titles in repeated rows and cards: they clamp to one line, with the full title on the item's own page.
Touches: COMP-21. Compatible: each item type keeps one frame ratio (stills 16:9, posters 2:3), so siblings of one type stay one height.
Strength: invariant

### APP-04 A create control on every list
Applies: Lists and collections the user can add to; all devices
Do: Show a create control on every list the user adds to, at the right end of its header or as its first row, never centered.
Why: Without a visible create control the user hunts for how to add.
Yes: `+ New meeting` at the right end of the Meetings header · `+ New task…` as the first row of the task list
No: `+ New meeting` centered in the header
Touches: TOUCH-04. Compatible: the create control sits in the list's own header or first row, never in the phone page header.
Strength: invariant

### APP-05 Bordered buttons and fields
Applies: Buttons and editable fields, not menu items, nav rows or list rows; all devices
Do: Draw every action, icon-only ones included, as a bordered button, and every editable field as a bordered box filled a shade off the page.
Why: Bare links, loose glyphs and borderless fields get missed and look unfinished.
Yes: `Show all` as a bordered button under the list, and a square bordered `×` close · A comment field with a border and a lighter surface than the page
No: `Show all ›` as bare link text · A lone `×` glyph with no button box
Touches: UI-11. Compatible: Hairlines, not boxes governs containers (sections, panels, cards); buttons and fields are controls and keep their borders inside any container.
Touches: APP-18. Compatible: the link to the rest of a capped section is drawn as a bordered Show all button.
Touches: APP-19. Compatible: a row's far-right control (a ★, a Remove) is a bordered button; a row that cycles a value is itself the target.
Strength: invariant

### APP-06 Actions hit the named target
Applies: Actions, shortcuts, swipes and bulk commands that change data; all devices
Do: Act only on a visibly selected or named item, show the destination before running, and give an action's key, swipe and bulk forms one effect.
Why: An action that lands on a guessed item, or somewhere unannounced, loses work.
Yes: `File to: Receipts ▾` on the File button, with `New folder…` in its menu · Swiping a row right and pressing its Done button do the same thing
No: A shortcut that archives whichever row the mouse last hovered
Touches: COMP-04. Compatible: Batch actions where batch is real decides when bulk actions exist; Actions hit the named target makes them match the single action.
Touches: UI-02. Actions hit the named target wins when an action's destination varies: the button names it (File to: Receipts ▾).
Strength: invariant

### APP-07 Controls sit in the flow
Applies: every control, button and picker on any page; all devices
Do: Place every control inside the bar, header or row it governs, never floating over content, and open pickers as the app's standard sheet or menu.
Why: Floating buttons cover content on phones and collide with titles; a one-off picker looks like another app.
Yes: The sidebar toggle sits in the top bar's leading slot · Sort controls sit in a header row directly above the list; a Tag picker slides up as the same sheet the More menu uses
No: A round + button floating over the bottom-right corner of the list
Touches: APP-19. Compatible: APP-07 keeps a control inside its row; APP-19 says where in the row it goes.
Touches: TOUCH-05. Compatible: pickers and menus open as the standard sheet; on touch, editors and chat open full screen instead.
Touches: APP-20. APP-07 Controls sit in the flow wins for the very first slot on desktop: the nav toggle leads and ‹ Back sits right after it, before the title.
Strength: invariant

### APP-08 User's place kept per item
Applies: scroll, draft, cursor and selection state; all devices
Do: Keep each item's scroll, draft, cursor and selection through view switches, pane toggles, tabs and Back; open another item at its saved place or top.
Why: Resetting or jumping the position costs the user their place on every switch.
Yes: Opening the Notes pane beside an article leaves the article at paragraph 6 · Back from a see-all page lands at the same scroll spot · The next email opens at its top
No: Clicking the Archived tab scrolls the page up to the tab strip
Touches: DESK-02. Compatible: APP-08 keeps scroll and selection across views; DESK-02 keeps the focus visible within one.
Strength: invariant

### APP-09 Rows identify their item
Applies: List rows, search results and pickers; all devices
Do: Give each row the details that tell its item apart without opening it, such as an image, date or place.
Why: People should not have to open items one by one to find the right one.
Yes: Agenda row: "2:30 PM · Dentist · 14 Main St" · A file picker row with a thumbnail, name and modified date
No: Five rows that each read only "Meeting"
Touches: UI-03. Compatible: Each fact shown once cuts values repeated or identical on every row (a chip always reading Active); a row's own date, place and image identify it and stay.
Strength: default

### APP-10 Human-readable dates
Applies: Displayed dates, times, progress fractions and media positions; all devices
Do: Write dates month first, weekdays with their day number, in 12-hour time; progress as done of the true total, positions out of their length.
Why: Machine and day-first formats are slow to read, and a bare weekday is ambiguous across weeks.
Yes: Tue Sep 15, 9:30am · 3/12 setup steps done; a podcast stopped at 9:42 of 23:41
No: 23 December 2025 · 3/3 when the checklist has 12 steps
Strength: invariant

### APP-11 Glyph plus word
Applies: Action buttons, menu options and top-level nav rows; all devices
Do: Prefer a conventional glyph beside each button, menu option and top nav label, except panel closes and rows too cramped for words; right-align nav counts.
Why: A glyph is found faster than a word, and a word removes doubt about the glyph.
Yes: A pencil glyph with "Edit" · A download-arrow glyph with "Download"
No: A bare "Play" text button
Touches: UI-03. Compatible: a button's glyph and its word are one label, not a repeated fact.
Touches: APP-14. Compatible: a label gets one glyph beside its word, and that glyph appears only once.
Touches: UI-02. Compatible: the word names the effect, and one glyph sits beside it.
Touches: UI-12. Compatible: the glyph is the conventional one, and it sits beside the word.
Touches: COMP-15. Compatible: a few peer options become tiles, each still one glyph with its word.
Touches: COMP-24. Panel close is a corner × wins for a panel's close control.
Touches: TOUCH-11. Cramped phone buttons go glyph-only wins on a touch screen when a word no longer fits its row.
Strength: default

### APP-12 Current look with a centerpiece
Applies: Every new or reworked page; all devices
Do: Prefer leading each new or reworked page with one large centerpiece (a live chart, cover image or animated logo) unless it pushes the task off-screen.
Why: Generic or dated layouts read as machine-made and cost the product the user's trust.
Yes: A dashboard led by one large live chart, the rest in quiet rows · A bakery's home page led by one large photo of its storefront
No: A grid of identical grey cards from a default template · A stock illustration above a settings form
Touches: PROC-06. Compatible: the centerpiece rule sets the target look; the design pass sets when a page is checked against it.
Touches: APP-18. Compatible: the centerpiece is the due-now content itself drawn large, never decoration placed above it.
Strength: default

### APP-13 Destructive actions sit apart
Applies: Delete, remove, block and spam actions in bars, rows, menus and viewers; all devices
Do: Put destructive actions inside More or at the far end from Edit and other frequent actions, never as small inline links or on search rows.
Why: A destructive control beside everyday ones gets pressed by accident.
Yes: Delete in the top-left corner of the full-size photo view, Edit at the right · `Block sender` inside the message's More menu
No: `done · spam · block` as small links under an email · A remove button on a search result row
Touches: UI-15. Compatible: A working control for every act requires the remove control; Destructive actions sit apart decides where in the view it sits.
Touches: TOUCH-06. Compatible: No destructive control under the palm adds the bottom-right exclusion on touch screens to Destructive actions sit apart.
Touches: COMP-17. Destructive actions sit apart wins for destructive actions: they go in More even when the bar has room.
Strength: invariant

### APP-14 One glyph per label
Applies: Button, chip, tab and menu labels; all devices
Do: Show each glyph at most once within a single label, counting glyphs a component adds on its own.
Why: A doubled glyph reads as a render bug and wastes narrow-screen width.
Yes: + Folder · ✓ Saved
No: + + Folder
Touches: UI-03. Compatible: Each fact shown once cuts a glyph repeating another element; this rule caps the same glyph inside one label.
Touches: APP-11. Compatible: a label gets one glyph beside its word, and that glyph appears only once.
Strength: invariant

### APP-15 Opaque, flush fixed bars
Applies: sticky headers, fixed top and bottom bars, menus over content or media; all devices
Do: Give sticky bars, fixed bars and menus over content an opaque background flush to their edges; only the safe-area inset sits below a bottom bar.
Why: A gap lets scrolled content bleed past a bar, and a dead band around it wastes space.
Yes: A sticky table header on a solid background; rows vanish cleanly beneath it · A photo viewer's bottom bar sits at the screen bottom with only the home-indicator inset below; a share menu over the photo is a solid panel
No: A 6px strip above a sticky header where rows show through while scrolling
Touches: UI-22. Compatible: bars and menus are opaque; a brief feedback wash over media stays faint.
Strength: invariant

### APP-16 Input capability decides interaction
Applies: any behavior that differs between touch and mouse-plus-keyboard; all devices
Do: Switch touch-versus-pointer behavior, such as nav shape, hover menus and swipe actions, on input capability (coarse pointer, no hover), never on window width.
Why: A narrow desktop window still has a mouse, and a wide tablet still has no keyboard.
Yes: iPad landscape at 1180px: touch navigation and swipe actions, no hover menus · Laptop window dragged to 600px: hover menus and pointer controls stay
No: @media (max-width: 768px) turns on swipe actions
Touches: TOUCH-08. Compatible: APP-16 decides who counts as touch; TOUCH-08 lists what touch drops.
Touches: TOUCH-11. Compatible: dropping a word when it no longer fits follows available room; Input capability decides interaction behavior, not layout.
Strength: invariant

### APP-17 Buttons offer the state's next act
Applies: Buttons tied to a job or state: downloads, recordings, replies, read/unread; all devices
Do: Make a button offer the act its item's state allows: Cancel or Stop while its job runs, Open once ready, Mark unread once read.
Why: A button stuck on its old label hides the way out and gets pressed again mid-work.
Yes: `Download` → `Cancel` while downloading → `Download` again if cancelled · `Open` as soon as the first file finishes, the rest's progress in the status line
No: `Downloading 45%` in the button, with Cancel hidden in More
Touches: UI-18. Buttons offer the state's next act wins when the running work can be cancelled or stopped: the button reads Cancel, not Saving….
Touches: UI-07. Buttons offer the state's next act wins when the finished state allows a further act: the control becomes that act (Open), not a bare ✓.
Strength: invariant

### APP-18 Current first, the rest capped
Applies: dashboards, home screens, search results and any long section; all devices
Do: Lead with what is due now or already the user's own, collapse backlogs like Overdue, and end each capped section with a Show all button.
Why: Uncapped backlogs bury today's work, and a silently cut list hides that more exists.
Yes: Home: today's agenda first, 'Overdue (4)' collapsed beneath it · Search: your three closest saved matches with a Show all button for the rest of them, then all results
No: An email group that stops after five rows with no link to the other twenty
Touches: APP-05. Compatible: the link to the rest of a capped section is drawn as a bordered Show all button.
Touches: APP-12. Compatible: the centerpiece is the due-now content itself drawn large, never decoration placed above it.
Strength: invariant

### APP-19 Row control at far right
Applies: a control that belongs to one row (add, rate, remove, cycle); all devices
Do: Put a row's own control at the far right of its first line; when that control cycles a value, the whole row is its target.
Why: A control wrapped onto its own line reads as unrelated, and a tiny cycling target gets missed.
Yes: Contact row: name and company at left, the ★ at the far right of the name line · Priority row 'Low ●○○': a tap anywhere on the row steps it Low, Medium, High, then off
No: A Remove button wrapped alone onto a second line under its row
Touches: APP-07. Compatible: APP-07 keeps a control inside its row; APP-19 says where in the row it goes.
Touches: APP-05. Compatible: a row's far-right control (a ★, a Remove) is a bordered button; a row that cycles a value is itself the target.
Strength: invariant

### APP-20 Back button place and target
Applies: every sub-page's top bar; all devices
Do: Put one bordered back button reading '‹ <previous page>' at the left of each sub-page's top bar, returning one step along the user's path.
Why: Missing, duplicated or fixed-target back controls leave users hunting for the way out.
Yes: Orders › Order 1042 › Refund: the Refund page shows ‹ Order 1042 · An order opened from Search shows ‹ Search
No: A second '← Back to list' link inside the page body
Touches: TOUCH-04. Compatible: Back is the header's first slot on sub-pages.
Touches: APP-07. APP-07 Controls sit in the flow wins for the very first slot on desktop: the nav toggle leads and ‹ Back sits right after it, before the title.
Strength: invariant

### APP-21 Reading text wraps short
Applies: Paragraphs of reading text (articles, emails, notes); wide screens
Do: Let lists and tables fill their pane, but wrap reading paragraphs near 70 to 80 characters, centered in the pane on very wide screens.
Why: Lines much longer than 80 characters are hard to track back to the next line.
Yes: At 1600px an email body sits in a centered column about 70 characters wide, while the inbox list fills its pane
Strength: default

### APP-22 Selection bar or actions on the item
Applies: Screens listing items the user acts on; all devices
Do: Prefer a selection bar for repeated, mechanical work like triage and bulk edits, and actions on the item itself where a screen is mostly read.
Why: A bar speeds repeated work; on a screen people mostly read, it adds a step and clutter.
Yes: An orders queue: select orders and a bar offers Ship, Print label, Refund · A contact card with Call and Email on the card itself
Strength: default
