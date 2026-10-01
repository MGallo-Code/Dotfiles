# Git Rules

- **Commits are authorized by default for in-scope work.** After the relevant checks
  pass, make atomic commits at natural checkpoints without asking for per-commit
  permission. Stage only the agent's own changes, preserve unrelated work, and report
  the resulting commit hash.
- **Publication and live operations remain separate authority.** Do not push, merge,
  open or submit a PR, deploy, promote, restart production services, mutate live data,
  or change live infrastructure unless Michael explicitly authorizes that action for
  the current task or an existing repository workflow explicitly defines it as
  automatic. Permission to commit does not imply permission for any of these actions.
- Simple one-liner commit messages
- No Co-Authored-By tag
- GitHub SSH alias: `git@github:`

## PR standards (shared repos: SBIC now, any shared repo later)

- **Prove it, don't promise it.** Don't report a PR as fixing a check on confidence. Push it, watch CI, and call it fixed only when the required check is GREEN on the PR. CI is the source of truth, not your confidence.
- **Flat PRs by default.** Branch every PR off `main` and keep it independently mergeable; do NOT stack a PR on another unmerged PR's branch. Independent PRs all clear in one approval pass and the merge queue lands them in order, whereas a stack serializes (each link can only merge after the one below it) and forces a rebase whenever a base changes. Stacking is a rare exception for genuinely coupled work on the same files; prefer to BUNDLE coupled work into one PR rather than split it into serialized PRs. Optimize for the fewest approval events on the critical path, not the smallest possible diffs.
- **Approve once, queue the rest.** When the approver OKs a batch, queue them all and let the merge queue merge them in order. Don't make him re-approve each one as others land. Only re-approval accepted: if the queue genuinely breaks a PR, fix that one and ask for re-approval of just it. (Shared repos only.)
- **Fix the root, don't stack band-aids.** Fix at the source on the platform. No near-duplicate PRs (two dependency PRs both rewriting the lockfile, a workaround on a workaround). Consolidate and unify.
- **The gate is the gate.** Required checks must be green BEFORE approval, not "red now, the queue will sort it out." Never weaken branch protection to move faster. Work with the queue, not around it.
- **Which repos gate on review.** None currently. `sbic-platform-corp/sbic-platform` used to require a second-engineer approving review as the SOC 2 change-management control, but that ruleset now has `required_approving_review_count: 0` and no SOC 2 window is running, so a green PR merges without waiting on anyone. `sbic-platform-corp/sbic-docs` and solo `MGallo-Code/*` repos were never review-gated. Read the live ruleset (`gh api repos/<owner>/<repo>/rules/branches/main`) rather than assuming a gate exists — do not invent an approver. Once Michael explicitly authorizes publication, merge/push directly without waiting on a review.

"Prove it," "fix the root," and "the gate is the gate" apply to solo repos too. "Approve once" and "flat PRs by default" are shared-repo-focused (solo repos merge on green, so a stack barely exists).
