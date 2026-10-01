# UI rules: the core 25

Read first for any UI work (step 1 of the workflow in `SKILL.md`). Wording and labels come first: they are the corrections Michael makes most.
Rule format and principles: `FORMAT.md` in this folder. A rule's Touches line names a rule it interacts with and which wins.

### UI-01 Copy about content, not machinery
Applies: All user-facing copy, labels, headers, status lines and approval prompts; all devices
Do: Write copy about user content in the user's words, never code terms, function names, database IDs, file paths, pipeline stages, version tags or decision logic.
Why: System talk is reading the user cannot act on, and it makes a finished product look unfinished.
Yes: Ships Tuesday · "Add Dana Ruiz to your contacts" on an approval card
No: Ships Tuesday (SLA rule 4 applied) · "contact_create id=4412" on that card
Touches: UI-07. Compatible: a failure or fallback line says what happened to the user's content, never how the system decided.
Touches: UI-08. Compatible: a refresh stamp tells the user how current their content is; Copy about content, not machinery bans text about how the system works.
Strength: invariant

### UI-02 Action labels name the effect
Applies: Button, menu item and action labels; all devices
Do: Label each action with the short verb or noun for what pressing it does, adding no count, qualifier, mechanism, list name, or consequence.
Why: Padded or mechanism-named labels slow scanning and make the user ask what pressing does.
Yes: Save, on a card that saves a recipe to favorites · Continue setup, when setup is half done
No: Create, on that same card · Delete (this will remove the file)
Touches: APP-11. Compatible: the word names the effect, and one glyph sits beside it.
Touches: APP-06. Actions hit the named target wins when an action's destination varies: the button names it (File to: Receipts ▾).
Touches: UI-05. Compatible: Action labels name the effect picks a button's word; One name per thing keeps that word the same everywhere the act appears.
Strength: invariant

### UI-03 Each fact shown once
Applies: Titles, headers, counts, readouts, chips, icons and status words; all devices
Do: Show each fact once per screen: cut any title, count, chip, icon or status word repeating another element, and any chip that never changes value.
Why: Repeats bury the lines that carry information and make the product read as machine-written.
Yes: A notifications switch shown on, with no "Enabled" word beside it · A panel under a tab named Notes, with no Notes title inside it
No: The same switch with the word "Enabled" beside it
Touches: APP-11. Compatible: a button's glyph and its word are one label, not a repeated fact.
Touches: UI-07. Compatible: repeats of on-screen facts are cut; a fact no element shows (failure, fallback, side effect, skip) keeps its line.
Touches: APP-09. Compatible: Each fact shown once cuts values repeated or identical on every row (a chip always reading Active); a row's own date, place and image identify it and stay.
Touches: COMP-01. Compatible: an editor's title is the one place inside it naming its record; Each fact shown once cuts only a second copy.
Touches: APP-14. Compatible: this rule cuts a glyph repeating another element; One glyph per label caps the same glyph inside one label.
Strength: invariant

### UI-04 Plain characters in copy
Applies: All shipped copy, including ready-to-paste messages; all devices
Do: Write copy with no em dashes, using a comma, colon or period instead, and no unrendered HTML entities such as &#39;.
Why: Em dashes and leftover entities mark text as machine-made and get pasted verbatim to real customers.
Yes: You're booked for Tue Sep 15: we'll email a reminder. · Saving… and 2 files · 14 MB
No: You&#39;re booked for Tue Sep 15 — we&#39;ll email a reminder.
Strength: invariant

### UI-05 One name per thing
Applies: Names of concepts, sections, tabs, lists, acts and destinations; all devices
Do: Give each concept, section and act one name everywhere, exactly as broad as what it covers; an act spanning item types uses each type's verb.
Why: Synonyms and duplicates read as different states or places, and the user cannot tell which is real.
Yes: "Completed" on the task row, its filter and its history · "Documents" heading a list of invoices, receipts and quotes; an activity log reading Paid for invoices and Signed for contracts
No: "Completed" on the row but "Done" in the filter · "Invoices" heading a list that also holds receipts and quotes
Touches: UI-02. Compatible: Action labels name the effect picks a button's word; One name per thing keeps that word the same everywhere the act appears.
Strength: invariant

### UI-06 Instructions match the screen
Applies: Help text, hints and instructions that name a control; all devices
Do: Name only controls present where the text is read, by their exact labels, and never contradict an example shown beside it.
Why: Text naming a missing or renamed button sends people hunting for it.
Yes: "Remove it from its page", where that page has a Remove button
No: "Click Archive" on a screen whose button reads File
Strength: invariant

### UI-07 Status shown in place
Applies: Success, progress and error messages after an action; all devices
Do: Show status on the item or control it concerns, never a toast or floating pill; report a failure or skip in one line beside it.
Why: Floating notices cover content and vanish before they are read.
Yes: A shop's + on a product turns to ✓ once it is in the cart · "2 skipped: already paid" beside Mark paid after marking 40 invoices
No: A "Saved!" toast sliding up over the page
Touches: UI-03. Compatible: repeats of on-screen facts are cut; a fact no element shows (failure, fallback, side effect, skip) keeps its line.
Touches: APP-17. Buttons offer the state's next act wins when the finished state allows a further act: the control becomes that act (Open), not a bare ✓.
Touches: UI-18. Compatible: Every wait shows at once covers the wait; when it ends, Success shown in place decides what the control shows.
Touches: COMP-13. Finished item leaves the view wins when the open item is completed or removed: the view advances or closes, with no success line.
Touches: UI-01. Compatible: a failure or fallback line says what happened to the user's content, never how the system decided.
Strength: invariant

### UI-08 Statuses show only verified truth
Applies: Statuses, badges, counts, lists, empty states and tentative items; all devices
Do: Derive every status, count, list and empty state from current data, not hard-coded or stale values, updated without reload; mark unconfirmed items; timestamp synced lists.
Why: One false status makes every other status untrustworthy.
Yes: Completing a task changes `4 due today` to `3 due today` at once · A pending reservation in a dashed outline marked `not confirmed`; `Updated 9:42 am` above a synced order list
No: `Synced` on the dashboard while every save errors · Deleting rows from a capped list without the hidden ones moving up
Touches: UI-01. Compatible: a refresh stamp tells the user how current their content is; Copy about content, not machinery bans text about how the system works.
Touches: UI-10. Statuses show only verified truth wins once live data is wired: counts and empty states then show the real data, 'none' included; sample data fills only screens not yet wired.
Touches: COMP-06. Compatible: changes arrive on their own without reload; pull-to-refresh is the manual check on a synced source.
Strength: invariant

### UI-09 Started flows open on the task
Applies: Task screens (checkouts, bookings, chat), their menus, and the screen after Start; all devices
Do: Put no how-to text on task screens or their menus, and open a started flow on its first step; explain its scope before Start.
Why: Instructions restate what the controls already show and push the task down the screen.
Yes: An attach menu listing Photo, Voice, File · A new booking that opens on its first step, picking a date
No: The same menu headed "Pick one" · A new booking that opens on a screen explaining how booking works
Touches: COMP-02. Compatible: a setting's explanation waits behind its ?, so the task screen carries no coaching text.
Strength: invariant

### UI-10 Sample data stays in mocks
Applies: Mocks, dev builds and shipped screens; all devices
Do: Fill mocks and dev builds with real-looking sample data, never stubs or coming-soon pages; ship a screen only once its live data is wired.
Why: Stubs hide layout problems, and sample data in a shipped screen reads as real.
Yes: A contacts mock showing five sample contacts in its real layout
No: A shipped page reading "Coming soon" · Sample orders on a screen real customers can open
Touches: UI-08. Statuses show only verified truth wins once live data is wired: counts and empty states then show the real data, 'none' included; sample data fills only screens not yet wired.
Strength: invariant

### UI-11 Hairlines, not boxes
Applies: Sections, panels, lists, banners and cards; all devices
Do: Separate sections with a 1px line, never a box; run lists and banners full width, square-cornered, text on one left edge; cards only in grids.
Why: Decorative and nested boxes double the borders, stack the padding and make panels look bulky or shifted.
Yes: Account settings: 'Notifications' and 'Billing' split by one 1px rule, each name on the page title's 16px line · A product grid where every card sits on the same soft shadow
No: A bordered 'Billing' card inside a padded, bordered settings panel · A list in a 24px padded, rounded wrapper, so row text starts at 40px
Touches: APP-05. Compatible: Hairlines, not boxes governs containers (sections, panels, cards); buttons and fields are controls and keep their borders inside any container.
Touches: UI-20. Compatible: a full-width list adds no padding of its own; each row pads its text to the shared gutter, equally on both sides.
Strength: invariant

### UI-12 One conventional meaning per glyph
Applies: Icons on controls, marks and status indicators; all devices
Do: Give each action or state the simple outline glyph whose everyday meaning it is, filled only when on, and never reuse it for another meaning.
Why: Clever, ornate, or borrowed glyphs make users guess and cause wrong presses.
Yes: A trash can on Clear · A check mark marking a task done · Delete as a trash can, never the ⌫ backspace glyph
No: A broom on Clear · A blue dot marking a task done, which reads as unread
Touches: APP-11. Compatible: the glyph is the conventional one, and it sits beside the word.
Strength: invariant

### UI-13 Shared components and style variables
Applies: Every screen in any app: bars, rows, cards, dialogs, menus, search; all devices
Do: Render each repeated element through the app's one existing component, adding options for real differences, and take fonts, spacing and colors from global variables.
Why: Lookalike copies drift in padding and behavior, and every restyle then has to be repeated per copy.
Yes: A new Invoices page uses the existing page header, list row and bottom bar components unchanged. · Customer, job and invoice search share one search screen and one result row, with the kind passed as data.
No: A new Invoices page with a hand-built header that mimics the shared one, padded 14px instead of the spacing variable.
Touches: PROC-07. Compatible: mocks use the app's shared components, which is what keeps shipped parts unchanged.
Touches: PROC-03. Changes stay inside the ask wins on existing screens: swapping a lookalike for the shared component in a way that changes its look waits for his go-ahead.
Strength: invariant

### UI-14 One control per intent
Applies: Buttons, menus, toggles and gestures serving one intent on a screen; all devices
Do: Prefer one visible control per intent, variants as its options, and none where existing taps, drags or keys already do it on every device.
Why: Two controls for one intent leave the user wondering which is real.
Yes: `Export ▾` holding CSV and PDF · A list row that opens from the row itself or Enter, with no Open button
No: `Resume` and `Open` side by side, both reopening the same document · A `Message us` button beside a chat box that is always open
Touches: UI-15. Compatible: One control per intent limits how many controls an intent gets; Every enabled control works requires each shown control to work.
Strength: default

### UI-15 Every enabled control works
Applies: Every item, page, overlay and control, on each device and in each state
Do: Give every act an item or overlay supports, close and remove included, a working control in its view; remove controls and pages that do nothing.
Why: A control that does nothing makes the user doubt every other control.
Yes: A photo viewer with its own Delete, and a × that closes it on one click · `Download` gone once every file is downloaded
No: A `Theme` menu item that does nothing when clicked · An order page telling the user to email support to cancel, with no Cancel button
Touches: UI-14. Compatible: One control per intent limits how many controls an intent gets; Every enabled control works requires each shown control to work.
Touches: APP-01. Compatible: a greyed control holding its slot (Actions hold fixed slots) is visibly unavailable; Every enabled control works bans controls that look usable and do nothing.
Touches: APP-13. Compatible: A working control for every act requires the remove control; Destructive actions sit apart decides where in the view it sits.
Strength: invariant

### UI-16 Confirm only what can't be undone
Applies: Deletes, removes and discards; all devices
Do: Ask once before a permanent delete or discarding unsaved work; anything an Undo can bring back runs at once, without asking.
Why: A question before every reversible act slows work and trains people to click through the one that matters.
Yes: Empty trash → "Delete 12 items forever?" `Cancel` `Delete` · Archive a message: gone at once, Undo brings it back
No: "Remove this task?" on a list where Undo restores it
Strength: invariant

### UI-17 Looking never changes data
Applies: Opening, viewing, previewing and scrolling; all devices
Do: Change data only on a control press: opening or viewing never adds to a list, marks done, starts a session or timer, or opts in.
Why: People open things to look; side effects of looking corrupt their data and their trust.
Yes: Opening a recipe shows Save; it joins the saved list only when Save is pressed · Opening a time-tracking project starts no timer until Start is pressed
No: Opening a product page adds it to the cart
Strength: invariant

### UI-18 Every wait shows at once
Applies: Taps, clicks, drags, view switches, loads and buttons that start work; all devices
Do: Answer every input without perceptible lag; while work runs, disable and relabel the pressed button (Saving…) and run a slim bar under the top bar.
Why: A silent wait looks broken and invites a second press.
Yes: `Save` turns to greyed `Saving…` the moment it is pressed · Next day swaps the agenda instantly; a pane divider tracks the cursor frame by frame
No: Each day switch reloads the whole page · A loading bar drawn above the top bar
Touches: APP-17. Buttons offer the state's next act wins when the running work can be cancelled or stopped: the button reads Cancel, not Saving….
Touches: UI-07. Compatible: Every wait shows at once covers the wait; when it ends, Success shown in place decides what the control shows.
Strength: invariant

### UI-19 Layout fits its container
Applies: Every page, pane and dialog at every width; all devices
Do: Size layouts to their container, stacking columns before they squeeze, never overlapping or truncating; only shelf rows, and last-resort wide tables, scroll sideways.
Why: Overlap, clipping and sideways page scroll are the commonest broken-layout reports.
Yes: Closing a side pane widens the main column into the freed space · A row of product cards scrolls sideways inside its row; the page never does
No: A two-column form squeezed to 150px fields at phone width
Touches: APP-03. APP-03 wins for titles in repeated rows and cards: they clamp to one line, with the full title on the item's own page.
Touches: TOUCH-03. Compatible: TOUCH-03 is how a phone meets UI-19 without clipping.
Touches: COMP-19. Compatible: a dialog that fits shows every field with no inner scrollbar; a layer taller than the screen scrolls as a whole.
Strength: invariant

### UI-20 One owner per gap
Applies: Padding, margins and gaps of boxes, headings and neighbors; all devices
Do: Each box pads itself, equally on opposite sides and matching its children's gap, with section space above headings and at least 4px between neighbors.
Why: Two owners for one gap drift apart, leaving lopsided padding and headings that float away from their content.
Yes: A comment form padded 12px on all sides, 12px between the text box and its buttons · An 'Upcoming' heading with section space above it and its first row right beneath
No: A form padded 24px on top and 8px at the bottom · A count badge and its label fused as '3Unread'
Touches: UI-11. Compatible: a full-width list adds no padding of its own; each row pads its text to the shared gutter, equally on both sides.
Strength: invariant

### UI-21 Default view holds the frequent
Applies: what a screen shows before anything is expanded or chosen; all devices
Do: Prefer showing only what most visits use; put rare settings, details and legal terms behind More or the choice needing them; make optional setup skippable.
Why: Always-visible controls for occasional use bury daily actions, and a forced optional step can stop someone from starting.
Yes: A shop owner's home shows today's orders with Ship; tax settings live under Settings · The return policy shows only once 'Request a return' is chosen; 'Invite your team' has Skip and waits in Settings
No: Storage used printed under every uploaded file instead of on the account page
Touches: COMP-17. Compatible: Show every action that fits fills an action bar, most used first; Default view holds the frequent keeps rare settings, details and setup out of a screen's default view.
Strength: default

### UI-22 Theme-safe color and contrast
Applies: Every color, tint and fill in light, dark and any other theme; all devices
Do: Keep text at 4.5:1 and page, panel and callout tones distinct in every theme, saturated color only on state, actions and selection, at full strength.
Why: Hard-coded colors break other themes, and low-contrast text or look-alike panels go unreadable in one of them.
Yes: A tip callout one tone darker than the page in both themes · Swipe right reveals solid green with a bold 'Complete'
No: A callout box at #f7f7f7 on a #fafafa page · A pale mint swipe reveal with thin grey text
Touches: APP-15. Compatible: bars and menus are opaque; a brief feedback wash over media stays faint.
Strength: invariant

### UI-23 Primary right, others to its left
Applies: Action rows in dialogs, forms and task screens, not bottom action bars; all devices
Do: Put the primary at the right end, Cancel beside it, other secondaries further left, and leave-or-destroy actions like Discard draft at the far left.
Why: One fixed spot for the primary action lets people press it without reading.
Yes: `Discard draft` … `Cancel` `Save` · `Preview` `Publish`, Publish at the far right
No: `Save` at the left of a form, `Cancel` at the right
Touches: COMP-17. COMP-17 wins on bottom action bars: most used first from the left, More last.
Strength: default

### UI-24 Feature parity across devices
Applies: every feature and fix in a product used on phone and desktop
Do: Ship each feature and fix to phone and desktop through one shared feature layer under device-tailored layouts; only keyboard-bound tasks like coding may be desktop-only.
Why: Work checked only on desktop leaves the phone missing whole sections or rebuilt with drift.
Yes: Meeting notes open, edit and delete on the phone, in a phone layout · A 12px section margin fixed on desktop is fixed at phone width in the same change · Undo is a tappable control on the phone, not only Cmd+Z
No: A separate phone page, rebuilt from scratch, that has no Edit
Touches: TOUCH-08. Compatible: TOUCH-08 gives keyed actions their touch controls.
Strength: invariant

### UI-25 Compact by default
Applies: Spacing on every page; all devices
Do: Prefer compact spacing in tools, about 12px between sections and 6px within a row, from shared spacing variables; showcase pages may run roomier.
Why: Loose spacing pushes content off screen, and one-off values drift apart page by page.
Yes: Sections 12px apart on an admin dashboard · A client's landing page with 32px between sections, still from the spacing scale
No: A 24px gap between a list and its own heading in a tool
Strength: default
