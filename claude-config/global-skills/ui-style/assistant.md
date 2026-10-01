# UI style: Chat and assistant

Open when: building a chat or AI-assistant interface.
Rule format and principles: `FORMAT.md` in this folder. A rule's Touches line names a rule it interacts with and which wins.

### CHAT-01 Assistant sees the current screen
Applies: Embedded assistant or chat panel inside an app; all devices
Do: Send the assistant the user's current page, selection and playback position with every message, leaving out any content locked from the assistant.
Why: A screen-blind assistant makes the user restate what is already in front of them.
Yes: Viewing Tuesday on the calendar, "move my 3pm to Friday" moves Tuesday's 3pm event with no follow-up question · Paused at 12:40 in a recorded webinar, "what was that chart?" is answered for that moment
No: Viewing Tuesday on the calendar, "move my 3pm to Friday" gets "Which day's 3pm do you mean?" · On a locked private-notes page, the note's text is sent to the assistant as context
Strength: invariant

### CHAT-02 Proposals wait for Confirm
Applies: AI-proposed creates, edits, deletes and inferred matches not pre-approved; all devices
Do: Show each proposed write as a Confirm/Dismiss card where proposed, writing nothing and pausing until answered, Dismiss ending the reply; run reads unasked.
Why: Silent automated writes put wrong data in the user's records.
Yes: `Update Jane Doe's address to 14 Main St? Confirm · Dismiss` under her email · "What's on Friday?" answers at once; "Add oat milk to the grocery list" shows a card and changes nothing until Confirm
No: An inferred appointment booked with no card · "What's on Friday?" first asks "Allow access to your calendar?"
Touches: UI-17. Compatible: Confirm on a proposal card is the explicit choice Only an explicit choice means yes requires.
Touches: CHAT-05. Compatible: Proposals wait for Confirm gates the write; Proposal cards show subject, change, source sets what the card shows.
Touches: CHAT-09. Compatible: this rule decides which acts need approval; that one lets the user pre-approve chosen reversible kinds.
Touches: UI-11. Proposals wait for Confirm wins for a pending proposal: it sits in its own card, outside any grid, until answered.
Strength: invariant

### CHAT-03 Chat speakers shown by position
Applies: Two-party chat transcripts, such as assistant or support chats; all devices
Do: Show who is speaking by alignment and a distinct background per speaker, with no visible name label per message; keep names for screen readers.
Why: A YOU or AGENT label on every bubble repeats what position already shows and crowds the text.
Yes: User messages right-aligned on an accent-tinted background, assistant replies left on a plain one
No: Every message headed YOU or ASSISTANT
Touches: UI-03. Compatible: in a chat, position and surface already show the speaker, so a per-message name label is a repeat.
Touches: UI-22. Compatible: the user's surface marks the speaker, so a tint of the accent is allowed; its text still meets 4.5:1.
Strength: invariant

### CHAT-04 Assistant shows it is working
Applies: Assistant or chat panels waiting on a model; all devices
Do: Stream the reply as it generates, show whether it is working, waiting on the user or stuck, and end a stall in a visible error.
Why: A silent assistant looks hung, leaving the user unsure whether to wait or retry.
Yes: `Working… reading 3 emails` with a moving indicator · `No response for 2 min · Retry` after a stall
No: A spinner that spins forever after the model has died
Touches: CHAT-07. Compatible: a one-line live status (Working…, waiting, stuck) shows while the reply runs; the model's thinking and intermediate artifacts stay collapsed.
Strength: invariant

### CHAT-05 Proposal cards show subject, change, source
Applies: Proposal cards and any value inferred from someone's words; all devices
Do: Head a card with its subject's name and image, then an added/removed/changed summary expandable in full, and keep source words and reasoning beside inferred values.
Why: Unreadable proposals and hidden sources get wrong changes approved.
Yes: A card headed by a contact's photo and name, then `+ 2 phone numbers · − 1 old email`, with `Show all` · `Sunday afternoon` shown beside the normalized `Sun 12–5 pm`
No: A card reading `task 4812 → list 77`
Touches: CHAT-02. Compatible: Proposals wait for Confirm gates the write; Proposal cards show subject, change, source sets what the card shows.
Strength: invariant

### CHAT-06 Auto-scroll of streaming output
Applies: chat transcripts and other streaming output; all devices
Do: Auto-scroll streaming output only while the user is at the bottom; once they scroll up, hold their position until they return to the bottom.
Why: Snapping back mid-read makes earlier content, and the controls in it, unreachable.
Yes: Scrolled up to open 'Thinking' while a reply streams: the view stays put · At the bottom: new lines keep scrolling into view
No: Each new chunk snaps the view back to the bottom
Touches: APP-08. Compatible: CHAT-06 is the streaming case of keeping the user's place.
Strength: invariant

### CHAT-07 Model working kept collapsed
Applies: AI assistant replies and AI-generated results; all devices
Do: Show the model's answer by default; keep its thinking, tool-call output, drafts, and provider or model name collapsed behind a toggle until opened.
Why: Machine working shown by default buries the answer and turns a task screen into a debug view.
Yes: A reply with a collapsed grey Thinking toggle above it
No: A draft outline and raw tool-call output printed above the answer
Touches: UI-01. Compatible: model working may exist behind a toggle; copy shown by default stays about content.
Touches: CHAT-04. Compatible: a one-line live status (Working…, waiting, stuck) shows while the reply runs; the model's thinking and intermediate artifacts stay collapsed.
Strength: invariant

### CHAT-08 Chat history survives close and stop
Applies: Assistant and chat threads; all devices
Do: Keep every message through close, Stop and later sends, never repeating one; mark Stop in the thread; Clear empties the panel but history keeps it.
Why: Wiped or duplicated threads lose work and apply the same change twice.
Yes: After Stop, the partial reply stays, marked `Stopped` · `Clear` empties the panel; the conversation stays in the log
No: Reopening the panel re-sends the last question · A follow-up message clears the thread and re-runs the earlier request, creating two identical events
Touches: COMP-20. Compatible: Started work finishes unattended keeps the work running; Chat history survives close and stop keeps its record whole.
Strength: invariant

### CHAT-09 Auto-approve per kind, reversible only
Applies: Approval settings for an assistant acting on the user's own records and accounts; all devices
Do: Offer a per-kind auto-approve switch, off until the user turns it on, never covering acts no undo reverses: sending, deleting, paying.
Why: Approving every routine write by hand slows delegation, but an auto-approved send or delete cannot be taken back.
Yes: Tasks set to auto-approve: the assistant's new task appears with no card · Calendar events set to auto-approve: a proposed event deletion still shows a card
No: A single "approve everything" switch that also lets the assistant send email unasked
Touches: CHAT-02. Compatible: that rule decides which acts need approval; this one lets the user pre-approve chosen reversible kinds.
Touches: UI-17. Compatible: switching on auto-approve for a kind is the explicit choice; it never covers sending, deleting or paying.
Strength: invariant
