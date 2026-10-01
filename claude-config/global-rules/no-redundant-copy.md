# No Redundant Copy

Say only what the screen, or the finished action, doesn't already say. Michael scans:
filler is what he reads past to reach the thing, and it reads as machine-written, which
erodes trust in the lines that do carry information.

## UI copy
- A label names the thing. It does not explain its own mechanic, restate what's visible,
  or reassure.
  - "Draft", not "Draft - wraps, does not scroll".
  - "Delete", not "Delete (this will remove the file)".
- No line narrating an action the user just took and can see the result of (a "you denied
  this" sentence under a card that already shows it was denied).

## Agent behavior
- Be compliant; don't announce compliance. Doing the thing is the evidence.
- Don't read the instruction back before obeying it ("As you asked, I'll now...").
- Don't name the rule you're following or caption each step with the requirement it meets.

## The test
Before shipping any label, status line, settled state, or sentence of narration: what does
it tell him that the screen (or the completed action) doesn't? If nothing, cut it.

## Scope
- The failure is saying the OBVIOUS, not the SUBSTANTIVE. Keep reasoning in design docs,
  briefs, commit messages, and explanations of a real trade-off: they exist to say what
  isn't visible.
- Still state what the screen can't show: a failure, a fallback, a side effect, a skipped
  step.
