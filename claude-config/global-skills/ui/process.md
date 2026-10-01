# UI rules: Process

Open when: planning, mocking, reviewing or reporting on UI work with Michael.
Rule format and principles: `FORMAT.md` in this folder. A rule's Touches line names a rule it interacts with and which wins.

### PROC-01 Mock when the fix has options
Applies: Any visible change, including small fixes; not backend-only changes
Do: When a visible change has several reasonable designs, show the options at 390 and 1280px before building; build clear fixes, then show before and after.
Why: A mock round on a one-way fix costs a day; building a contested design wastes the build.
Yes: Two header layouts as screenshots in chat, built after his pick · Off-center icon: fixed, then before and after shown
Touches: PROC-02. Compatible: Approved mock before visible changes gets the approval; Build matches the approved mock builds it. A wanted deviation beyond fixing the mock's own inconsistencies goes back through a revised mock.
Touches: PROC-07. Compatible: Approved mock before visible changes sets which areas and widths a mock covers; Mock screens show what ships sets how each screen is built.
Touches: PROC-04. Compatible: a mock shows him phone portrait and desktop; before sending, every mock screen is checked at all five widths and every theme.
Strength: invariant

### PROC-02 Build matches the approved mock
Applies: Building any UI from a mock he approved
Do: Build approved mocks exactly, checked beside them at their widths; deviate only where mock values meant to match differ, listing each in the closing report.
Why: Builds drift from a design he already approved, or faithfully copy the mock's own sizing slips.
Yes: Mock draws two cards in one row at 180px and 176px: both built at the card size token, logged 'mock 176, built 180, because cards in a row match'. · Mock puts Save bottom right on a form: built bottom right, confirmed in paired screenshots at 390 and 1280.
No: Mock puts Save bottom right: the build moves it top right because it looked cleaner, with no log entry.
Touches: PROC-01. Compatible: Approved mock before visible changes gets the approval; Build matches the approved mock builds it. A wanted deviation beyond fixing the mock's own inconsistencies goes back through a revised mock.
Touches: PROC-03. Changes stay inside the ask wins when an approved mock redraws settled parts it was not meant to change: keep them as shipped and point out the slip.
Touches: PROC-06. Compatible: the design pass happens on the mock, before approval; the build then matches the approved mock.
Strength: invariant

### PROC-03 Changes stay inside the ask
Applies: Any UI change, restyle or refactor, in any app
Do: Change only what he flagged or an approved mock introduces, by the amount asked; every other element, view and function stays exactly as it was.
Why: Unasked or oversized changes break approved work and trade one flaw for a worse one.
Yes: 'The heading could be a tiny bit smaller': 20px to 18px, and nothing else on the card moves. · 'Restyle the booking calendar': new colors and spacing, with the day, week and month views all still there.
No: 'Restyle the booking calendar': a cleaner design that drops the week view. · A refactor that also nudges a button 4px because it looked off.
Touches: PROC-02. Changes stay inside the ask wins when an approved mock redraws settled parts it was not meant to change: keep them as shipped and point out the slip.
Touches: PROC-09. Compatible: for a reported defect the ask is every instance of its pattern, not only the example he named.
Touches: UI-13. Changes stay inside the ask wins on existing screens: swapping a lookalike for the shared component in a way that changes its look waits for his go-ahead.
Strength: invariant

### PROC-04 Screenshots at every width and theme
Applies: Any visible change, mocks included, before showing it to him or calling it done
Do: Screenshot every page that uses a changed component or shared style at 390, 768, 1024, 1280 and 1600px in every theme, and look at each.
Why: Overflow and console checks pass on pages that are cramped, lopsided, clipped or half empty at some width.
Yes: Changed the site header: screenshotted all 12 pages at 390, 768, 1024, 1280 and 1600 wide, light and dark, and read every image. · New pricing-table mock: checked at all five widths before sending, and fixed a clipped last column at 768.
No: Changed the site header: ran a no-horizontal-overflow script and a console check, and looked at the home page on desktop only.
Touches: PROC-07. Compatible: Mock screens show what ships sets what a mock contains; Screenshots at every width and theme checks each mock screen at every width before he sees it.
Touches: PROC-01. Compatible: a mock shows him phone portrait and desktop; before sending, every mock screen is checked at all five widths and every theme.
Strength: invariant

### PROC-05 Affected workflows used firsthand
Applies: Any visible or usable change, before calling it done or saying 'try it'
Do: Run every workflow through a changed page by keyboard, pointer and touch (an emulated touch phone counts), in Safari (WebKit) and one other browser.
Why: A change that passes its own test can still break the flows around it.
Yes: After a booking change: book, edit and cancel by keyboard and mouse in Safari and Chrome, then by touch in a phone-sized browser
Strength: invariant

### PROC-06 Whole-page design pass
Applies: New or reworked pages and their mocks, and any page after about five small fixes
Do: Match new or reworked pages' spacing, cards, borders and fields to the latest approved pages; after five small fixes, mock the same match for approval.
Why: A page that only works, or drifts through piecemeal fixes, looks generic and inconsistent.
Yes: A new settings page restyled to match the recently redesigned inbox before it is shown · After five small fixes, a mock evening out spacing, cards, borders and fields while keeping the content
No: A new settings page shown working but still in older card and field styles than the redesigned inbox · Adding one field to an existing form, then restyling the rest of the page unasked
Touches: APP-12. Compatible: the centerpiece rule sets the target look; the design pass sets when a page is checked against it.
Touches: PROC-02. Compatible: the design pass happens on the mock, before approval; the build then matches the approved mock.
Strength: invariant

### PROC-07 Mock screens show what ships
Applies: Every mock of a change to an app that already has pages
Do: Build mocks as running pages from the real rendered pages: shipped parts unchanged, every planned piece present and working, notes outside each screen's border.
Why: A mock that misdraws today's screen, fakes controls or puts notes in the UI gets judged on the wrong things.
Yes: Mock of a new filter chip: the live orders page with its real toolbar, the chip added and filtering rows when clicked, a '1' marker in the margin. · Mock of a comment editor: bold, attach and mention all respond; the existing close button stays where it is today.
No: Mock of a new filter chip: a redrawn toolbar missing one existing button, with a '1' marker sitting on the chip. · Mock of a new delete button that deletes a real invoice when clicked.
Touches: PROC-01. Compatible: Approved mock before visible changes sets which areas and widths a mock covers; Mock screens show what ships sets how each screen is built.
Touches: PROC-04. Compatible: Mock screens show what ships sets what a mock contains; Screenshots at every width and theme checks each mock screen at every width before he sees it.
Touches: UI-13. Compatible: mocks use the app's shared components, which is what keeps shipped parts unchanged.
Strength: invariant

### PROC-08 Vague complaints treated as defects
Applies: Any UI complaint he makes, including a vague 'looks off'
Do: Log each complaint in the project's issue file, open until fixed; for a vague one, ask what looks off against what, and measure that.
Why: He has been right each time something 'looked off'; dismissed or unlogged complaints come back.
Yes: 'The date looks less centered': asked 'against the row or the icon?', measured it 3px high against the row, logged it. · 'Checkout feels cramped on phones': logged, asked which gap, measured 4px between price and button at 390 wide.
No: 'The date looks less centered': measured the date inside its own box, found it centered, closed as no defect.
Touches: PROC-09. Compatible: Vague complaints treated as defects logs and pins down the defect; Fixes cover and guard every instance sets how far the fix reaches.
Strength: invariant

### PROC-09 Fixes cover and guard every instance
Applies: Fixing any UI defect he reported
Do: Fix the defect wherever its code or a copy of it appears, and add an automated check over all pages that fails if it returns.
Why: Single-instance fixes leave copies elsewhere, and unguarded fixes regress when later work touches the same layout.
Yes: Extra padding reported on one table: removed from all six tables sharing the class, plus a test over every page's tables. · Swipe-to-delete misfired in one list: fixed the shared swipe handler, checked all four lists, added a regression test.
No: Extra padding reported on one table: fixed that table; the other five and any test left for later. · Extra padding reported on one table: also restyled a similar-looking list that never had the extra padding.
Touches: PROC-03. Compatible: for a reported defect the ask is every instance of its pattern, not only the example he named.
Touches: PROC-08. Compatible: Vague complaints treated as defects logs and pins down the defect; Fixes cover and guard every instance sets how far the fix reaches.
Strength: invariant

### PROC-10 Only deliberate writes reach records
Applies: Agents testing on a user's real account or data
Do: When testing ends, delete every test item you created in the user's real records and revert test edits, including history and log rows.
Why: Leftover test items and edits clutter real data and pass for things the user did.
Yes: After testing folder sharing on his real account, the three test folders are deleted · After editing a real contact's phone number to test the form: the edit and its history entry reverted, the old number back
No: Test folders left in his account after the check passed · A folder he named 'Test' himself deleted because it looked like test data
Strength: invariant

### PROC-11 Mark picks start wide
Applies: Choosing a logo, app icon or assistant mark
Do: Offer about 10 candidates at their real display size when he picks a logo, app icon or assistant mark.
Why: A mark has to be judged at the size it will live at, and a few options rarely include the one.
Yes: Ten app-icon candidates shown at 60px and 180px, each lettered
Strength: default
