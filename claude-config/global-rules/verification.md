# Verification

Prove a change on its real output before calling it done, not by reading the code or the tests alone.

- **Anything visible** (a UI, page, component, mock, review page, chart or rendered document): follow the `ui` skill from the start. Its rules, a mock when there is a real choice, a live check in a browser, a review against the rules, then show Michael.
- **Data processing** (imports, transforms, migrations, reports): run it on real or realistic input and inspect the actual output (sample rows, counts, totals, the rendered result) against what is expected.
- Skip only what has no output to inspect.
