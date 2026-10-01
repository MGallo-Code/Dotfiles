# UI rules: Components

Open when: building or changing a component: forms, lists, tables, dialogs, menus, pickers, editors, media.
Rule format and principles: `FORMAT.md` in this folder. A rule's Touches line names a rule it interacts with and which wins.

### COMP-01 One editor for create and edit
Applies: Creating and editing records the user owns, not read-only copies synced from another service; all devices
Do: Each create or Edit control opens the record's one full editor, titled with it, prefilled with saved values or the context it opened from.
Why: Create-only or blank editors force delete-and-recreate and lose data.
Yes: Edit beside invoice line 3 opens 'Editing line 3 of Invoice 1042' with its amount, tax and note filled in · Add event on Dana Ruiz's contact page opens 'New event with Dana Ruiz'
No: Saving an edited address adds a second address · Add event on that page opens a blank event form
Touches: UI-03. Compatible: an editor's title is the one place inside it naming its record; Each fact shown once cuts only a second copy.
Strength: invariant

### COMP-02 Settings teach themselves
Applies: Setup flows and settings screens; all devices
Do: Prefer setup that starts from a working default with examples, presets and demos, needed non-obvious settings explained behind a ?, unclear optional controls cut.
Why: A bare wall of settings with hidden meaning gets configured wrong or abandoned.
Yes: A new shop taking orders on sensible defaults before seeing any setting · `Two-step sign-in (?)` whose ? opens one plain sentence on hover, focus or tap
No: A `Sync mode: Mirror / Merge / Push` toggle kept with a paragraph explaining it
Touches: UI-09. Compatible: a setting's explanation waits behind its ?, so the task screen carries no coaching text.
Strength: default

### COMP-03 One area per screen, hubs only when earned
Applies: Top-level areas of a multi-area app, and settings sections; all devices
Do: Give each area its own nav entry or tab opening on its content; open on a category hub, All first, only when several merit browsing.
Why: A hub with one or two entries is an extra click with nothing to choose.
Yes: Settings: Account · Billing · Notifications tabs, one showing · A Files area with eight folders opens on a hub, All files first
No: A hub page holding just Inbox and Sent
Touches: DESK-03. Compatible: One area per screen shows one app area at a time; DESK-03 lays out that area's supporting panes beside its main pane.
Strength: default

### COMP-04 Batch actions where batch is real
Applies: Lists where users routinely act on many rows at once, like inboxes and order queues; all devices
Do: Prefer offering all-at-once actions and a Select mode (from More, or long-press on touch) whose bulk bar closes when nothing is selected.
Why: Acting on many items one at a time is tedious where batch work is the job.
Yes: `Approve all` above five pending expense reports, each uncheckable · `Mark all read` for a folder, then a Select bar that disappears when the last row is unpicked
No: A Select mode on a settings list nobody batches
Touches: APP-06. Compatible: Batch actions where batch is real decides when bulk actions exist; Actions hit the named target makes them match the single action.
Touches: COMP-22. Compatible: long-press on a row starts Select; only the ≡ grip drags it.
Strength: default

### COMP-05 Nav placement by frequency of use
Applies: Choosing which destinations the global nav shows; all devices
Do: Group daily destinations into a few labeled nav sections, fold rare ones under More, and remove never-used, empty or absorbed pages rather than repurposing them.
Why: A long flat nav buries daily destinations, and stale entries read as broken dead ends.
Yes: Daily (Home, Orders, Inbox) · Catalog · More ▸ Reports, Settings · A page whose job moved into Tasks leaves the nav
No: An empty Actions page relabeled History to keep it in the nav
Touches: COMP-12. Compatible: COMP-05 decides where an entry sits; COMP-12 says it appears once.
Strength: invariant

### COMP-06 Pull-to-refresh on synced lists
Applies: Lists of remotely synced data (mail, calendars, feeds); touch and desktop
Do: Refresh synced lists by a pull that tracks without lag, arms past about 100px, fires on release with a spinner, and disarms if pushed back.
Why: Apple Mail's long, tracking pull is the model; a short or laggy one fires by accident.
Yes: Pull the inbox 120px and release: spinner, then new mail · Pull, push back up, pull again without lifting: it re-arms
No: Refresh fires the moment the pull crosses 40px, before release
Touches: TOUCH-09. Compatible: COMP-06 spells out the pull-to-refresh case.
Touches: UI-08. Compatible: changes arrive on their own without reload; pull-to-refresh is the manual check on a synced source.
Strength: invariant

### COMP-07 Shelf search stays on its shelf
Applies: Search box opened from one section or single-kind shelf; all devices
Do: Scope a section's search to that section's content type, name the scope in its field, and leave all-content search to the global search.
Why: An unscoped section search buries the wanted item among other kinds sharing its name.
Yes: On Help, "refund" lists only articles and the field reads "Search help" · In a Customers section, "Smith" returns only customers
No: On Help, "refund" lists a past order first
Strength: invariant

### COMP-08 Inputs match their valid values
Applies: Form fields with fixed choices, and numeric adjusters (pickers, steppers, sliders, offsets); all devices
Do: Give fixed-choice fields a picker, not free text, needing no step after the pick, and numeric fields a range covering real use, never silently clamped.
Why: Free text, extra load steps and silent clamps let wrong values in and throw corrections away.
Yes: `Time zone ▾` listing zones, and a month picker that loads March the moment it is picked · A quantity stepper that accepts 1 to 999
No: A free-text Country field · A quantity stepper that snaps 150 back to 99
Strength: invariant

### COMP-09 Ask only what the task needs
Applies: Forms, quizzes, logging and rating flows; all devices
Do: Prefer only the fields the task needs, and one tap for a frequent judgment or log, with deeper detail optional but reachable.
Why: Unneeded fields clutter focused screens and turn quick logging into a chore.
Yes: A newsletter signup with only an email field and Subscribe · Logging a glass of water with one tap, the amount editable after
No: A required phone-number field on that newsletter signup · A five-field form required for every water log
Strength: default

### COMP-10 Text boxes grow and keep text
Applies: Editors, answer boxes and composers; all devices
Do: Grow editors to fit content, no inner scrollbar, caret visible, line breaks kept; a bottom-pinned composer grows to a set height, then scrolls inside.
Why: An inner scrollbar hides the user's own text; an uncapped pinned box covers the thread.
Yes: A notes editor that lengthens as lines are added · A chat box that grows to five lines, then scrolls
Strength: invariant

### COMP-11 Content in its real form
Applies: Rendered content: chat replies, emails, imported notes, rich text and code; all devices
Do: Render content in its real form: formatted markdown, native email HTML, images not links, no escape characters, and code in monospace on a faint tint.
Why: Raw markup, flattened code and link-only photos are hard to read and look broken.
Yes: A product description shows its bullet list and bold terms, not asterisks · Command output in a monospace block on a slightly darker background, not an indented paragraph
No: An imported note showing '\#Heading' and a bare https://…/photo.jpg link · An email flattened to plain text with a screenful of blank lines
Strength: invariant

### COMP-12 Each destination once, on every page
Applies: Global navigation (side nav, phone menu, top bar), Home and section landings; all devices
Do: Show one global nav on every page, each destination once, nothing page-specific, the app's logo opening Home and each section entry its landing page.
Why: A missing entry makes a section look deleted, and a doubled one makes users wonder which door is real.
Yes: Invoices appears once in the side nav and once in the phone menu; the logo opens Home · Enter on Products opens the Products landing page
No: A Quick links menu listing exactly the sidebar's entries · A Products › Overview row beneath Products
Touches: COMP-05. Compatible: COMP-05 decides where an entry sits; this says it appears once.
Touches: DESK-04. Compatible: a collapsed side nav still sits on every page behind its toggle; DESK-04 sets its default state, COMP-12 its contents.
Strength: invariant

### COMP-13 Finished item leaves the view
Applies: Detail views and viewers opened from a list; all devices
Do: Once the open item is completed or removed, show the next item in its list, or close the view when none remains.
Why: A finished item left open makes the action look like it failed.
Yes: Completing the open task shows the next task · Deleting the last photo in the viewer closes the viewer
No: The completed task staying open in its dialog
Touches: UI-07. Finished item leaves the view wins when the open item is completed or removed: the view advances or closes, with no success line.
Strength: invariant

### COMP-14 Controls shown during a mode
Applies: editing, searching and typing modes; all devices
Do: While editing, searching or typing, hide controls that mode doesn't use; an open search shows only its field and, at the header's right end, Cancel.
Why: Controls irrelevant to the current mode crowd the working view and invite wrong taps.
Yes: Editing a note: the search bar is hidden until you finish · Phone search open: field plus Cancel, Cancel where the menu button was · Typing in chat on a phone: the button row hides and the transcript gets the room
No: Search open with a Go button and the menu still expanded
Touches: TOUCH-04. Compatible: an open search temporarily takes over the header.
Touches: TOUCH-08. Compatible: tapping a search button is a request to type, so its field may take focus.
Strength: invariant

### COMP-15 Few options as square tiles
Applies: Menus and sheets of a few peer actions, like attach or share, not value choices; all devices
Do: Prefer one row of square tiles, glyph above a one- or two-word label, styled like the app's other buttons, unless an option needs a sentence.
Why: Options styled unlike the app's buttons look foreign and scan slower.
Yes: An attach menu of three tiles: camera over Photo, mic over Voice, page over File
No: The same three options as a plain text list
Touches: APP-11. Compatible: a few peer options become tiles, each still one glyph with its word.
Strength: default

### COMP-16 Photo zoom origin and swiping
Applies: full-size photo viewer; all devices, swipes on touch
Do: Zoom a full-size photo toward the pinch point or pointer, never a fixed corner; on touch, pinch to zoom and swipe sideways between photos.
Why: Zooming into a fixed corner hides the detail the user aimed at.
Yes: Pinch on a face at lower right: the face grows under the fingers · Swipe left: next photo
No: Ctrl+scroll anywhere zooms toward the top-left corner
Touches: TOUCH-09. Compatible: COMP-16 spells out the photo viewer's gestures.
Strength: invariant

### COMP-17 Show every action that fits
Applies: Item action bars and action rows with a More overflow; all devices
Do: Prefer filling the bar with every non-destructive action that fits at full size, most used first from the left, More last, the rest inside More.
Why: Hiding actions that would fit costs a tap on every routine task.
Yes: An order card showing `Ship` `Print label` `Message buyer` `Add note` and `More` · Three actions plus `More` on a phone bar that fits four buttons
No: Two actions and a `More` holding four more while the bar has room for six
Touches: TOUCH-07. Compatible: Thumb-sized touch targets sets the minimum size; Show every action that fits fills the bar at that size.
Touches: APP-13. Destructive actions sit apart wins for destructive actions: they go in More even when the bar has room.
Touches: UI-23. Compatible: rows that finish a step (dialogs, forms, activities) end in the primary at the far right; an item's action bar runs most used first from the left, More last.
Touches: UI-21. Compatible: Show every action that fits fills an action bar, most used first; Default view holds the frequent keeps rare settings, details and setup out of a screen's default view.
Strength: default

### COMP-18 Menu toggle doubles as close
Applies: buttons that open menus, sheets and overlays; all devices
Do: Make the button that opens a menu or overlay also close it from the same spot, showing the real open state however it was opened.
Why: A second close elsewhere, or a toggle out of sync, makes the user hunt and double-tap.
Yes: ☰ turns to × in the same box while the menu is open · Opening the menu by keyboard also turns ☰ to ×
No: The sheet draws its own × over the page title while ☰ stays behind it
Touches: COMP-19. Compatible: COMP-18 sets the toggle; COMP-19 sets outside input.
Touches: COMP-24. Menu toggle doubles as close wins for a layer opened by a toggle in view: that toggle becomes its ×; the corner × is for panels with no toggle in view.
Strength: invariant

### COMP-19 Input while a layer is open
Applies: open menus, popovers, sheets and overlays; all devices
Do: While a layer is open, scrolls and taps act only inside it, an outside click closes a menu or popover, and a too-tall layer scrolls.
Why: Scroll bleed and stray taps move the page under an open layer and lose the user's place.
Yes: Scrolling in the open chat panel never moves the page behind · Clicking the map closes the open filter menu · A help sheet taller than the screen scrolls
No: The page behind an open menu sheet scrolls under a swipe
Touches: COMP-18. Compatible: COMP-18 sets the toggle; COMP-19 sets outside input.
Touches: UI-19. Compatible: a dialog that fits shows every field with no inner scrollbar; a layer taller than the screen scrolls as a whole.
Strength: invariant

### COMP-20 Started work finishes unattended
Applies: Long-running jobs, uploads and assistant replies; all devices
Do: Collect a long job's required input before it starts, and keep it running after its panel or app closes until it finishes or is stopped.
Why: Mid-run prompts and silent cancels drop work the user expected to finish.
Yes: A backup asking for the password on its first screen, then running alone · Closing the chat mid-reply; reopening shows the reply finished
No: Closing an export dialog cancelling the export it started
Strength: invariant

### COMP-21 Image shape by context
Applies: Thumbnails, covers, attached photos and image viewers; all devices
Do: Never stretch or squash images: shelves of like items crop to uniform cells, collages keep each shape at one row height, viewers show them whole.
Why: Distorted images look broken, and mixed cell sizes break a shelf.
Yes: A row of product photos cropped to identical square cells · Three receipt photos, one portrait and two landscape, side by side at one height; tapping one shows it whole
No: A portrait photo squashed into a square cell
Touches: APP-03. Compatible: a shelf is uniform siblings; a collage row shares one height.
Strength: invariant

### COMP-22 Where a drag may start
Applies: Reorderable lists, sliders, scrubbers and draggable regions; all devices
Do: Reorder user-ordered lists only by dragging a ≡ grip handle, or Alt+↑/↓ on desktop; drags and scrubs never select text or scroll the page.
Why: When long-press both selects and drags, touch misfires, and stray text selection hijacks scrubbing.
Yes: Checklist rows show ≡; dragging ≡ moves the row, long-pressing the row selects it · Alt+↓ moves the focused row down one
No: Long-pressing anywhere on a row lifts it for dragging · Dragging a price slider highlights the label text beside it
Touches: COMP-04. Compatible: long-press on a row starts Select; only the ≡ grip drags it.
Strength: invariant

### COMP-23 Title left, tools right
Applies: Top bar at 768px and wider; any input
Do: Prefer the title at the left with search, sized to its role, and every other secondary control packed against the right gutter.
Why: A control stranded mid-bar belongs to neither end and splits the header.
Yes: 'Customers' at left; a 280px search and an Export button flush against the right gutter
No: A search field centered in the middle of a 1440px top bar
Strength: default

### COMP-24 Panel close is a corner ×
Applies: Close control of panels, dialogs and sheets, not a form's Cancel beside Save; all devices
Do: Close a panel with a square red × button in its top-right corner, sized like its other header buttons, never a text Close button.
Why: A text Close wastes header space, and a close that moves between panels must be hunted for.
Yes: A settings panel with a square red × in its top-right corner
No: A "Close" text button at the panel's foot
Touches: APP-11. Panel close is a corner × wins for a panel's close control.
Touches: APP-02. Compatible: the × sits top-right and fills and centers in its square button.
Touches: COMP-18. Menu toggle doubles as close wins for a layer opened by a toggle in view: that toggle becomes its ×; the corner × is for panels with no toggle in view.
Strength: invariant
