# Visual Verification

For any change that produces something I can SEE (UI, pages, components, charts/
graphs, rendered PDFs/docs, dashboards, anything with visible output), do not stop
at code review or unit tests. Verify it live and show me before calling it done.

## Verify with Playwright
- Use the connected Playwright MCP (`mcp__*playwright*` tools), NOT chrome-devtools.
- Drive the running app/page: load it, exercise the change, take screenshots, and
  read console/network for errors. Confirm the change actually renders correctly,
  not just that the code looks right.

## Review against the UI rules
- Before calling UI work done, run the `ui-review` skill: it walks the change against the UI style rules (`ui-style.md` and the `ui-style` skill), wording first, and fixes what fails.

## Show me, visibly, before any PR
- Open the result in a real browser on my screen where possible: start the dev
  server and `open <localhost url>` (macOS) so I can look at what you added.
- A headed/visible Playwright session or screenshots are an acceptable substitute
  when opening my actual browser is not possible. Sometimes that alone is enough.
- Do this BEFORE opening a PR or declaring the work finished. Rule of thumb:
  "show me locally with Playwright before you PR anything."

## Scope
- Applies to frontend/UI work and to any generated visual artifact (graphs, charts,
  reports, documents).
- Skip for backend-only, CLI, or library changes that have no visible output.
