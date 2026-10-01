# UI rules: Phone and tablet

Open when: anything that runs on a phone or tablet, or takes touch input.
Rule format and principles: `FORMAT.md` in this folder. A rule's Touches line names a rule it interacts with and which wins.

### TOUCH-01 Swipe direction for each verb
Applies: swipeable list rows; touch devices
Do: Swipe right runs a row's positive action; left removes it, or runs a second action where rows can't be removed; visible buttons also offer both.
Why: Swipes that differ per list feel unsafe, and swipes without a visible button hide verbs from anyone who hasn't found them.
Yes: Tasks: right Complete, left Remove · Mail: right File, left Trash · Bank transactions: right Categorize, left Flag, since transactions can't be removed
No: Shopping list: left swipe marks Got it
Touches: TOUCH-09. Compatible: TOUCH-09 sets how a swipe feels; this sets which verb it runs.
Strength: invariant

### TOUCH-02 Phone viewport stays put
Applies: text inputs, the on-screen keyboard and the status bar; touch (phone/tablet, or any touch input)
Do: Use 16px or larger input text, keep the focused field above the keyboard, respect safe-area insets, and match the status bar to the screen.
Why: iOS zooms into small inputs, the keyboard hides the field being typed in, and the clock draws over content.
Yes: A 16px message box: tapping it opens the keyboard with no zoom, the box and its attach button still in view · A dark photo viewer with a dark status bar and no content under the clock
No: A 14px search input that zooms the page when focused
Strength: invariant

### TOUCH-03 Phone width goes to content
Applies: Timeline rails, images beside text, and wide diagrams at phone width (under 768px)
Do: On phones, spend no content width on rails or side images: run timeline lines in the margin, keep media inline, and turn wide diagrams vertical.
Why: A phone cannot spare a column for decoration, and a wide diagram clips or scrolls sideways.
Yes: An order-tracking timeline's line and dots sit in the 16px page margin; entries use the full width · At 390px a relationship graph becomes a vertical list of links
No: A 48px timeline rail plus an 80px side thumbnail leaving 200px for text
Touches: UI-19. Compatible: TOUCH-03 is how a phone meets UI-19 without clipping.
Strength: invariant

### TOUCH-04 Phone header on one line
Applies: Page header at phone width (under 768px); any product
Do: Keep the phone header one line: Back on sub-pages, title, then only controls fitting at full size; collapse search to a magnifier before anything wraps.
Why: A wrapped or crowded header pushes content down and looks broken.
Yes: ‹ Orders · Order 1042 · 🔍 on one row
No: A title wrapping to two lines beside three squeezed buttons
Touches: APP-20. Compatible: Back is the header's first slot on sub-pages.
Touches: COMP-14. Compatible: an open search temporarily takes over the header.
Touches: APP-04. Compatible: the create control sits in the list's own header or first row, never in the phone page header.
Strength: invariant

### TOUCH-05 Full-screen panels on touch
Applies: editors, chat and assistant panels, multi-pane workspaces; touch devices
Do: On touch, open editors and chat panels full screen, never as partial sheets; at phone width, split multi-pane workspaces into full-width tabs, one pane showing.
Why: A partial sheet leaves no room to read once the on-screen keyboard is up.
Yes: Tapping Messages on an iPad opens the chat edge to edge · Phone: Document · Comments · History as a full-width tab row, one pane showing
No: Chat opens as a sheet covering 80% of the phone screen
Touches: DESK-04. Compatible: device split; this rule is touch, DESK-04 is desktop.
Touches: APP-07. Compatible: pickers and menus open as the standard sheet; on touch, editors and chat open full screen instead.
Strength: invariant

### TOUCH-06 No destructive control under the palm
Applies: Delete, remove and other destructive controls; touch (phone/tablet, or any touch input)
Do: Never place a destructive control in a touch screen's bottom-right corner, including a bottom bar's right-most slot; move it into More.
Why: An accidental brush of the palm should never delete something.
Yes: A phone bar of `Complete` `Priority` `Reschedule` `More`, with `Remove` inside More
No: `Remove` as the bottom-right tile of a phone action bar
Touches: APP-13. Compatible: No destructive control under the palm adds the bottom-right exclusion on touch screens to Destructive actions sit apart.
Strength: invariant

### TOUCH-07 Thumb-size targets
Applies: Tappable controls, nav rows and action tiles; touch (phone/tablet, or any touch input)
Do: Make every tappable control at least 44px with body-size labels, primary controls larger, moving extra actions to More instead of shrinking them.
Why: Small targets cause mis-taps, and small labels misreads, on a phone held in one hand.
Yes: A 44px square × on a photo viewer · Four 48px buttons on a phone toolbar with the rest under More; a checkout's Pay button at 56px
No: Seven 30px icons squeezed into one phone row · A 24px trash icon in the corner of a photo
Touches: COMP-17. Compatible: Thumb-sized touch targets sets the minimum size; Show every action that fits fills the bar at that size.
Strength: invariant

### TOUCH-08 No keyboard affordances on touch
Applies: key hints, keyboard navigation modes and text-field focus; touch devices of any width
Do: On touch devices, show no key hints or shortcut help, run no letter-key navigation, auto-focus no text field, give every keyed action a touch control.
Why: Key hints are noise without a keyboard, and an auto-focused field throws the keyboard over the content.
Yes: Reply and Archive buttons on an iPad, with no R and E key hints · Opening a new expense on a phone leaves the keyboard down until the note field is tapped
No: A wide iPad shows the keyboard shortcut list because its window is desktop-wide
Touches: APP-16. Compatible: APP-16 decides who counts as touch; this lists what touch drops.
Touches: COMP-14. Compatible: tapping a search button is a request to type, so its field may take focus.
Strength: invariant

### TOUCH-09 Native feel of touch gestures
Applies: swipe, pull, pinch and drag gestures; touch devices
Do: Match each touch gesture to its platform-native version; a row swipe locks horizontal once started and, when committed, slides fully off over its action color.
Why: Invented or loose gestures fire by accident, snap like glitches, and feel wrong to hands trained on native apps.
Yes: Swiping a task right while drifting 20px down keeps sliding sideways; the list stays still · A committed swipe slides the row off over green before the next row moves up
No: The list scrolls when a sideways swipe drifts down · The next row snaps into place with no slide-off
Touches: COMP-06. Compatible: COMP-06 spells out the pull-to-refresh case.
Touches: TOUCH-01. Compatible: TOUCH-01 sets which verb a swipe runs; this sets how it feels.
Touches: COMP-16. Compatible: COMP-16 spells out the photo viewer's gestures.
Strength: invariant

### TOUCH-10 Native photo picker and camera
Applies: Photo and file inputs; touch (phone/tablet, or any touch input)
Do: Open the device's native photo picker or camera from every photo input, accepting several files at once.
Why: Custom pickers and one-at-a-time uploads make adding photos slow.
Yes: `Add photos` opening the phone's library with multi-select, beside `Take photo`
No: A photo input that takes one image per tap
Strength: invariant

### TOUCH-11 Phone button rows overflow into More
Applies: Rows of buttons in headers and bars; touch, or any screen under 768px wide
Do: When a phone button row overflows, move its least-used actions into More first; only if it still overflows, show glyphs alone with accessible names.
Why: A bare glyph is harder to read than a word, so it is the last thing to give up.
Yes: Edit · Share · More, with Duplicate and Export inside More
No: Five glyph-only buttons while More is empty
Touches: COMP-17. Compatible: COMP-17 fills the row; this rule says what leaves first when it overflows.
Strength: default
