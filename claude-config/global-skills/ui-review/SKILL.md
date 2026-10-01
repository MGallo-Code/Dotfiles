---
name: ui-review
description: Review a UI change against Michael's UI style rules before calling it done. Use after building or changing any user interface (web page, app screen, component, mock or review page), before reporting the work finished, and whenever asked to review a UI.
---

# UI review

Walk the change against the rules in `~/.claude/rules/ui-style.md` and the `ui-style` skill, wording first, and fix what fails before reporting the work done.

1. **Collect the change.** Gather the diff, plus the rendered screens at phone and desktop widths (live, per the visual-verification rule). A rule about what the screen shows is judged on the screen, not the code.
2. **Wording first.** Check every visible string against UI-01 to UI-08 (copy about content, labels name the effect, each fact once, plain characters, one name per thing, instructions match the screen, status in place, verified statuses) and the no-redundant-copy rule. These are the corrections Michael makes most.
3. **Then the rest.** Walk the remaining always-on rules, then each `ui-style` topic file whose trigger matches the work (core, components, touch, desktop, assistant, personal tools).
4. **Fix, then report.** Fix every failure you can. Report what was checked, what was fixed, and anything left, as a table of rule ID, where (screen or file:line), the problem and the fix. Anything left goes under "not done" in the closing report.
