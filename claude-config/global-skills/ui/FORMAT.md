# How a UI style rule is written

Every rule in the library uses this shape. Fields are one line each unless noted.

```
### ICON-03 One glyph per label
Applies: button, chip and menu labels; all devices
Do: Show each glyph at most once in a label.
Why: A doubled glyph reads as a render bug and wastes phone width.
Yes: `+ Playlist` · `✓ Saved`
No: `+ + Playlist`
Touches: ICON-02 (icon plus word). Compatible: ICON-02 adds one icon; this rule caps repeats.
Strength: invariant
```

- **ID + name.** ID is a file prefix plus a number. The name is 6 words or fewer and names the property the rule governs ("One glyph per label"), never a category ("Cut repeated symbols").
- **Applies.** 15 words or fewer. The surface (component, state) and the device scope, stated concretely: `all devices`, `touch (phone/tablet, or any touch input)`, `desktop (keyboard + fine pointer)`, or a component (`chat composer`, `video player`, `calendar views`). A model does not generalize a rule past its stated scope, and over-applies a rule with no scope.
- **Do.** One sentence, 25 words or fewer, stated positively ("show X", "put Y at Z"), concrete enough that someone could check a screen against it. Name the target, not only the ban. Never "keep things consistent", "make it clean", "every screen": say which property, which value.
- **Why.** One clause, 20 words or fewer: the failure the rule prevents. The model generalizes from the reason.
- **Yes / No.** Literal strings or short concrete descriptions. A minimal pair: Yes and No differ ONLY in the property this rule governs. One or two Yes lines; a No line only where it marks the boundary a reader could get wrong. Examples never carry information the Do line lacks (the model must be able to follow Do alone). Use generic product strings, not one app's screens, unless the rule is app-specific. Vary the domain across Yes lines so they are not copied literally.
- **Touches.** Only when another rule governs the same element. Name it, then either `Compatible: <why both hold>` or `<ID> wins when <condition>`. The same note appears in both rules. Unscoped conflicts make models pick one arbitrarily.
- **Strength.** `invariant` (always holds; the only place ALWAYS/NEVER wording is allowed) or `default` (a judgment call, written as "Prefer X unless Y").
- **Check.** Optional. One line a reviewer or script can run ("no label string contains the same non-letter glyph twice").

## Principles

1. One rule per observable property. Split an umbrella whose clauses would make an agent do different things; merge rules that ask for the same thing.
2. Remove a conflict by scoping first (device, component, state). Declare precedence only for a real trade-off, and write it in both rules.
3. Directive first, examples second. An example may illustrate the Do line; it may never be the only place a requirement lives.
4. No emphasis words (CRITICAL, MUST, IMPORTANT, capitals). Invariants say "always" or "never" once, plainly.
5. A rule earns its place only if deleting it would change what an agent builds. Cut anything another rule already implies, and anything an existing always-loaded rule already says.
6. Plain words. No internal jargon, no rule-speak ("surface", "affordance", "grammar") unless the reader would use it.
