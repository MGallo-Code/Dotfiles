---
description: Package the given info and/or conversation context into a self-contained prompt file in ~/Downloads/ to hand off to another agent.
argument-hint: [instructions, or "based on this conversation", or both]
---

# Handoff

Turn a task into a **nicely-packaged, self-contained prompt file** written to
`~/Downloads/`, ready to paste into or feed to another agent (Claude Code, Codex,
a fresh session, a teammate's assistant) that has **zero memory of this
conversation**.

## Input: `$ARGUMENTS`

The user supplies one of three shapes. Detect which:

1. **Flat instructions** — they describe the task directly. Your job: sharpen and
   structure it, fill obvious gaps, then write the file. Improve it; do not just
   transcribe.
2. **"based on this conversation"** (or similar) — pull the task from the current
   session's context. Reconstruct what needs doing from what we've been working on.
3. **Both** — instructions PLUS a pointer to context ("based on this convo, but
   focus on the parser bug"). Merge them; the explicit instruction wins on conflict.

If `$ARGUMENTS` is empty, default to shape 2 (this conversation).

## Hard rules for the output file

- **Self-contained.** A fresh agent with no history must be able to act on it
  alone. Strip every "as we discussed", "the file from before", "you remember".
  Inline the real facts: absolute paths, exact symbol/function names, commands,
  error text, URLs, version numbers. If you reference a file, give its full path.
- **Agent-agnostic.** Do not assume tool names, slash commands, MCP servers, or a
  specific harness. Write for "whoever picks this up." If a specific tool IS
  required, say so explicitly as a prerequisite.
- **No secrets.** Do not embed credentials, tokens, or private message contents.
  If the task needs them, name the source ("read the token from ~/.config/...")
  instead of pasting the value.
- **Right altitude.** Enough context to succeed, not a transcript dump. Prefer the
  decisions and constraints over the back-and-forth that produced them.
- **Carry work state for multi-step tasks.** Include the `## State` block from the template
  below when the work spans phases or is handed off after compaction. Do not rely on the
  receiving agent to infer approved decisions, open questions, or commit permission from prose.
- **Carry a resume capsule for long work.** Include the next exact action and the
  evidence path for the last completed gate. A fresh agent should continue from
  files and state, not from reconstructed chat memory.

## Steps

1. **Resolve scope.** If the task is genuinely ambiguous (unclear deliverable,
   missing target repo, undefined success), ask 1-2 sharp questions first. If it's
   clear, proceed without ceremony.
2. **Draft the prompt** using the template below. Sharpen flat instructions;
   reconstruct conversation-based ones into concrete facts.
3. **Pick a filename:** `~/Downloads/handoff-<short-slug>-<YYYY-MM-DD>.md`
   (slug = 2-4 kebab words from the task; get the date via `date +%Y-%m-%d`).
   If that file exists, append `-2`, `-3`, etc. — never overwrite.
4. **Write the file**, then **report the absolute path** back and a one-line
   summary of what's inside. Offer to open it (`open <path>`) or revise.

## Output template

```markdown
# <Task title — imperative, specific>

## Objective
<One or two sentences: what done looks like.>

## State
<Include for multi-step work; omit for short, self-contained handoffs.>

- Michael-approved plans: `<paths; these control intent and scope>`
- Approved decisions:
  - <Decision Michael explicitly made, with date/source if useful>
- Open questions / blockers:
  - <Question that must be answered before continuing>
- Assumptions:
  - <Only reversible, logged assumptions; mark any unapproved/high-risk assumption clearly>
- Remaining work:
  - <Unfinished item, including verification tasks>
- Gates run: `<commands/checks + result>`
- Visual verification: `<not required | required but missing | verified + evidence>`
- PR/commit permission: `<not allowed | explicitly allowed for this action>`
- Last completed gate: `<gate + evidence path>`
- Next exact action: `<single next action the receiving agent should take>`

## Context
<Self-contained background. Why this exists, what's already true, what was
already tried. Absolute paths, real names, no "as discussed".>

## Inputs / relevant locations
- <absolute path or URL> — <what it is>
- <command to run, or data source>

## Task
1. <Concrete, ordered step>
2. <...>

## Constraints & gotchas
- <Things that will bite a fresh agent: env quirks, what NOT to touch, prior
  dead ends, style/convention requirements.>
- Treat the Michael-approved plan file(s) as source of truth for intent and scope. If anything appears to need
  a change, discuss the exact update with Michael and record approval before editing.

## Acceptance criteria
- [ ] <Verifiable condition for "done">
- [ ] <...>

## Prerequisites (if any)
<Tools, access, or setup the receiving agent must have. Omit if none.>
```

Keep the file tight and skimmable. Lead with the objective. Bullets over prose.
