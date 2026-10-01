#!/bin/sh
# check-agent-rules-hooks.sh - guards the trigger half of dotfiles INV-15.
#
# Dotfiles' post-commit, post-merge and post-checkout hooks regenerate the Codex combined
# rule file through ~/.dotfiles/scripts/regen-agent-rules.{sh,ps1}. They moved here from EA
# with claude-config (ADR-0006). If a hook is deleted, loses its exec bit, or stops calling the
# entrypoint, Codex silently falls behind Claude until the next sync (it did for 17 days
# before 2026-09-10). Asserts:
#   - each hook is tracked 100755 and hands off to .githooks/refresh-agent-rules
#   - refresh-agent-rules names both OS entrypoints
#   - hermetic behavior against a stub entrypoint: called with --quiet from every hook,
#     silent with no dotfiles checkout, one line when the entrypoint is missing, and the
#     hook exits 0 even when the regen fails
# Portable POSIX sh. Exit 0 = holds, 1 = regression.
set -u

ROOT="$(git rev-parse --show-toplevel)"
HOOKS="$ROOT/.githooks"
fail=0
pass() { echo "  ok    $1"; }
bad()  { echo "  FAIL  $1"; fail=1; }

echo "check-agent-rules-hooks: wiring"
for h in post-commit post-merge post-checkout refresh-agent-rules; do
    mode="$(git -C "$ROOT" ls-files -s ".githooks/$h" | cut -c1-6)"
    if [ "$mode" = "100755" ]; then pass "$h tracked executable"; else bad "$h tracked executable (mode '${mode:-untracked}')"; fi
done
for h in post-commit post-merge post-checkout; do
    if grep -q 'refresh-agent-rules' "$HOOKS/$h" 2>/dev/null; then pass "$h calls refresh-agent-rules"; else bad "$h calls refresh-agent-rules"; fi
done
for e in regen-agent-rules.sh regen-agent-rules.ps1; do
    if grep -q "scripts/$e" "$HOOKS/refresh-agent-rules" 2>/dev/null; then pass "refresh-agent-rules names $e"; else bad "refresh-agent-rules names $e"; fi
done

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) echo "check-agent-rules-hooks: behavior skipped on Windows (bash path only)";;
  *)
    echo "check-agent-rules-hooks: behavior (stub entrypoint)"
    T="$(mktemp -d)"
    trap 'rm -rf "$T"' EXIT
    out="$(HOME="$T/none" sh "$HOOKS/post-commit" 2>&1)"; rc=$?
    if [ "$rc" = 0 ] && [ -z "$out" ]; then pass "no dotfiles checkout: silent, exit 0"; else bad "no dotfiles checkout: silent, exit 0 (rc=$rc out=$out)"; fi
    mkdir -p "$T/home/.dotfiles/scripts"
    out="$(HOME="$T/home" sh "$HOOKS/post-commit" 2>&1)"; rc=$?
    case "$out" in *missing*) m=1;; *) m=0;; esac
    if [ "$rc" = 0 ] && [ "$m" = 1 ]; then pass "missing entrypoint: one line, exit 0"; else bad "missing entrypoint: one line, exit 0 (rc=$rc out=$out)"; fi
    printf '#!/usr/bin/env bash\necho "$*" >> "%s/calls"\nexit "${STUB_RC:-0}"\n' "$T" > "$T/home/.dotfiles/scripts/regen-agent-rules.sh"
    for h in post-commit post-merge post-checkout; do
        : > "$T/calls"
        HOME="$T/home" sh "$HOOKS/$h" >/dev/null 2>&1
        if [ "$(cat "$T/calls")" = "--quiet" ]; then pass "$h runs the entrypoint with --quiet"; else bad "$h runs the entrypoint with --quiet (got '$(cat "$T/calls")')"; fi
    done
    HOME="$T/home" STUB_RC=1 sh "$HOOKS/post-merge" >/dev/null 2>&1; rc=$?
    if [ "$rc" = 0 ]; then pass "failing regen still exits 0"; else bad "failing regen still exits 0 (rc=$rc)"; fi
    ;;
esac

if [ "$fail" -ne 0 ]; then echo "check-agent-rules-hooks: FAILED"; exit 1; fi
echo "check-agent-rules-hooks OK"
