# Smart Default: clarify -> spec -> plan on real build work

A library of workflow skills (from the forked `agent-skills` repo) is available in
every session. Use them to keep build work disciplined, but calibrate ceremony to
the task. Do NOT apply this to trivial edits, single-file tweaks, renames, or Q&A:
answer or do those directly.

For NON-TRIVIAL build work (new feature, multi-file change, new component or
service, anything you'd expect to take 5+ steps or to involve a real design
choice):

1. CLARIFY first. If scope, inputs, or success criteria are ambiguous, ask 1-3
   sharp questions (the question card, per `questions.md`) before writing code. Also clarify holes in an existing plan so
   the agent's understanding is explicit and does not replace user intent with
   assumptions. Do not guess at requirements. (Skills: `interview-me`,
   `idea-refine`.)
2. SPEC briefly. State what you're building and the acceptance criteria in 2-5
   lines, and get a nod if the direction is non-obvious. (Skill:
   `spec-driven-development`.)
3. PLAN the steps. List the files and edits you'll make before making them.
   (Skill: `planning-and-task-breakdown`.)

TDD is OPT-IN. Only write tests first, or add tests at all, when the user mentions
tests, testing, TDD, or coverage. Otherwise don't add a test burden they didn't
ask for. (Skill: `test-driven-development`, only when invited.)

Never let this gate block momentum on small work. When the user says "just do it"
or "you take the reins," make the call and proceed without hedging.

To see what's available, the `using-agent-skills` skill maps a task to the right
skill. Skills are workflows, not suggestions: when one clearly fits, follow it.
