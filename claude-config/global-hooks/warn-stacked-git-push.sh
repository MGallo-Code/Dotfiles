#!/usr/bin/env bash
# PreToolUse(Bash) guard: warn (NON-BLOCKING) before pushing a STACKED branch —
# one whose base is not `main`. Flat PRs off `main` are the default (see the
# "Flat PRs by default" rule in git.md): stacking serializes review and trips
# the base=main CI filter, so the required checks don't run on a stacked PR.
#
# It asks for confirmation (hookSpecificOutput.permissionDecision="ask") on a
# stacked push rather than silently allowing it, so a mistaken stacked push
# pauses for a deliberate yes — it never auto-approves a push. It exists because
# a rule in always-loaded guidance beats agent memory, and a mechanical nudge at
# the moment of action beats both.
#
# Detection is local (no network) and low-noise — a plain "branch != main" check
# would warn on every feature-branch push. Signal: some other UNMERGED origin/*
# branch is an ancestor of HEAD, i.e. this branch was built on top of another
# branch instead of on main. This catches the pre-PR case AND an open stacked PR
# (the base ref stays an ancestor of HEAD until it lands in main), and it
# self-clears once the base merges.
set -uo pipefail

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"

# Only react to git push commands; let everything else through untouched.
case "$cmd" in
  *"git push"*) : ;;
  *) exit 0 ;;
esac

# Need a git repo + a real branch (not detached HEAD); bail quietly otherwise.
branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || exit 0
[ -n "$branch" ] && [ "$branch" != "HEAD" ] || exit 0

reason=""
if git rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
  while IFS= read -r ref; do
    case "$ref" in origin/main|origin/HEAD|"origin/$branch") continue ;; esac
    if git merge-base --is-ancestor "$ref" HEAD 2>/dev/null \
       && ! git merge-base --is-ancestor "$ref" origin/main 2>/dev/null; then
      reason="branch '$branch' is stacked on unmerged '$ref' (not on main)"
      break
    fi
  done < <(git for-each-ref --format='%(refname:short)' refs/remotes/origin 2>/dev/null)
fi

# Not stacked → no decision, normal flow.
[ -n "$reason" ] || exit 0

jq -n --arg r "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "ask",
    permissionDecisionReason: ("Stacked push: " + $r + ". Default is flat PRs off main (git.md \"Flat PRs by default\"); stacking serializes review and trips the base=main CI filter. Confirm only if the stack is intentional."),
    additionalContext: "Otherwise: rebase onto main once the base merges, or bundle the coupled work into one PR."
  }
}'
exit 0
