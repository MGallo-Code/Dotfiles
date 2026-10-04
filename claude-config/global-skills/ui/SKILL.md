---
name: ui
description: Michael's UI workflow and rules. Use for any change someone can see (building, changing, mocking or reviewing a UI, page, component, review page, chart or rendered document), from the start of the work through to calling it done.
---

# UI workflow

Run these steps in order for any visible change. Skip it only for backend, CLI or library work with no visible output.

## 1. Read the rules that apply

- Always read `rules.md`: the 25 core rules, wording and labels first. They are the corrections Michael makes most.
- Then read each topic file whose trigger matches the work:
  - `core.md` (APP-): any app with more than one screen.
  - `components.md` (COMP-): forms, lists, tables, dialogs, menus, pickers, editors, media.
  - `touch.md` (TOUCH-): anything on a phone or tablet, or taking touch input.
  - `desktop.md` (DESK-): anything used on a desktop or laptop screen.
  - `assistant.md` (CHAT-): a chat or AI-assistant interface.
  - `personal-tools.md` (SOLO-): a tool only Michael uses, or a mock or review page for him. Never a client product or KeepTheCall.
  - `process.md` (PROC-): how to plan, mock, review and report UI work with him.
- Taste, from his own words:
  - clean simplicity with selective premium touches, not minimalism for its own sake;
  - start simple and add flair selectively;
  - color-match to the images or photos in use;
  - think about the end user (older users need clear headings);
  - keep spacing, borders and widths consistent;
  - real call-to-action buttons over subtle links.
- Rule format: `FORMAT.md`. A rule's Touches line names a rule it interacts with, and which wins.

## 2. Mock when there is a real choice

When a visible change has several reasonable designs, show the options at 390 and 1280 px before building (PROC-01), on the questions page with both screenshots per option (`questions.md`). Use real-looking sample data, never stubs (UI-10). Clear fixes skip the mock: build them, then show before and after.

## 3. Build

Use the app's shared components and style variables (UI-13). Build each change for every device the product runs on (UI-24).

## 4. Verify live

- Drive the running app or page with Playwright (the connected Playwright MCP, not chrome-devtools): load it, exercise the change, take screenshots at phone and desktop widths, and read the console and network for errors.
- Confirm that it renders and works, not just that the code looks right.

## 5. Review against the rules

Walk the change, on screen, against `rules.md` and the topic files you read: every visible string first, against UI-01 to UI-08 and the no-redundant-copy rule; then the rest. Fix every failure you can.

## 6. Show him, then report

- Open the result on his screen where possible: start the dev server and `open <localhost url>`. Screenshots or a visible Playwright session will do when that isn't possible.
- Do this before any PR or "done".
- Close with the report: done (and where to try it) and not done; anything from step 5 left unfixed goes under "not done". What needs his decision goes through the questions page or card (`questions.md`).
