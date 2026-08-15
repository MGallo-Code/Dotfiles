#!/usr/bin/env bash
# check-tcc-grants.sh  --  detect macOS TCC grant DRIFT before it silently takes the EA services down.
#
# THE FAILURE THIS EXISTS TO CATCH
# A TCC grant for a command-line binary is keyed to an ABSOLUTE, VERSIONED PATH:
#     /opt/homebrew/Cellar/node/26.3.1/bin/node
#     /Users/mike/.local/share/uv/python/cpython-3.12.13-macos-aarch64-none/bin/python3.12
# `brew upgrade node`, `brew upgrade uv` and `uv python upgrade` all move the real binary to a NEW
# versioned path. The grant does NOT follow it. From that moment every launchd job that execs the
# moved interpreter gets EPERM on ~/Documents -- and because a launchd job has no responsible
# application, tccd does NOT prompt, it silently denies (same mechanism as INV-9, different cause:
# INV-9 is "wrong KIND of binary", this is "right binary, moved out from under its grant").
# The services stay "loaded", the plists stay valid, and the logs just stop growing.
#
# WHY THIS SCRIPT INSISTS ON RUNNING FROM launchd  (the crux -- do not "simplify" this away)
# TCC attributes a file access to the RESPONSIBLE process. From a terminal or an agent session the
# responsible process is Terminal/Ghostty/claude-code, all of which hold their own Full-Disk or
# Documents grant, and that grant covers every child. MEASURED 2026-08-14: a python binary copied to
# an ungranted path read ~/Documents/EA/CLAUDE.md WITHOUT ERROR from an interactive shell. So an
# interactive run of this check CANNOT see the drift and would report a healthy machine while every
# launchd job was already dead. Only a run whose PPID is 1 reproduces the services' attribution.
# Hence: the verdict comes from the LaunchAgent; `--verify-via-launchd` is the by-hand entry point.
#
# TWO DETECTORS, deliberately different in kind:
#   1. MOVED (primary)  - each plist's effective interpreter is resolved to a realpath and compared
#      against a recorded baseline. An upgrade changes that realpath, and the grant stays on the old
#      one. Needs no TCC read, execs nothing, cannot hang, and is equally valid from any context.
#      It fires the night of the upgrade, while the RUNNING services are still healthy on the old
#      binary - they only break when they next restart. That gap is the "before" in this script.
#   2. ACCESS (confirming) - the interpreter is actually exec'd to open() a file under ~/Documents.
#      Catches a grant revoked WITHOUT a path change, which detector 1 cannot see. Only run against
#      paths that did not move (those hold a grant, so tccd answers from the database immediately).
#
# Usage:
#   check-tcc-grants.sh                       run both detectors in THIS context
#   check-tcc-grants.sh --verify-via-launchd  kickstart the agent and report its AUTHORITATIVE verdict
#   check-tcc-grants.sh --simulate-drift      fixture self-test: proves the detector fires (safe)
#   check-tcc-grants.sh --diag                isolate START vs CTRL vs DOCS per interpreter
#   check-tcc-grants.sh --explain             read-only TCC.db diagnostic: WHICH grant went stale
#   check-tcc-grants.sh --accept-baseline     record current paths as good (ONLY after re-granting)
#   check-tcc-grants.sh --install-launchagent write + load com.ea.tcc-drift (daily 03:25)
#
# This script NEVER writes to TCC.db and never invokes tccutil. It reads the databases read-only,
# and only in --explain.
#
# Env overrides:  TCC_CHECK_TARGET, TCC_CHECK_AGENT_DIR, TCC_CHECK_STATE_DIR
set -euo pipefail

TARGET="${TCC_CHECK_TARGET:-$HOME/Documents/EA/CLAUDE.md}"       # the file every probe tries to open
AGENT_DIR="${TCC_CHECK_AGENT_DIR:-$HOME/Library/LaunchAgents}"
STATE_DIR="${TCC_CHECK_STATE_DIR:-$HOME/.local/state/tcc-drift}"
STATUS_FILE="$STATE_DIR/status"
REQUEST_FILE="$STATE_DIR/request"
BASELINE_FILE="$STATE_DIR/baseline"       # declared program path -> realpath it resolved to
ALARM_SUPPRESS="${ALARM_SUPPRESS:-0}"
BACKUP_LOG="$HOME/Library/Logs/nexus-backup.log"                 # the log INV-1 already says to monitor
LABEL="com.ea.tcc-drift"
# The subtree whose access we are guarding. A job is IN SCOPE iff its plist (or its wrapper script)
# names this path, so a new EA service joins the check automatically and jellyfin/keepthecall do not.
GUARDED_ROOT="${TCC_CHECK_GUARDED_ROOT:-$HOME/Documents}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}\xe2\x9c\x93${NC} $*"; }
warn() { echo -e "  ${YELLOW}!${NC} $*"; }
err()  { echo -e "  ${RED}\xe2\x9c\x97${NC} $*" >&2; }

[ "$(uname -s)" = "Darwin" ] || { err "TCC is macOS-only (this is $(uname -s)) - nothing to check"; exit 0; }

# launchd execs our program directly, so PPID is 1. Any other parent means we inherited somebody
# else's TCC responsibility and our probes prove nothing about the services. This is the one fact the
# whole script hinges on, so it is derived from the process tree, never from an env var a hand-run
# could set.
context_is_launchd() { [ "$PPID" = "1" ]; }
context_name() { if context_is_launchd; then echo "launchd"; else echo "inherited"; fi; }

# ---------------------------------------------------------------------------------------------
# Discovery. Never a hardcoded list: read the installed LaunchAgents, so a new service joins by
# existing. Mirrors INV-9's resolution rule (follow the /usr/bin/env trampoline and its VAR=val
# prefixes; nothing else is followed).
# ---------------------------------------------------------------------------------------------
PLATFORM_PREFIXES='/usr/bin/ /bin/ /usr/sbin/ /sbin/ /System/ /usr/libexec/'
is_platform_binary() {
    local p="$1" pre
    for pre in $PLATFORM_PREFIXES; do case "$p" in "$pre"*) return 0 ;; esac; done
    return 1
}

plist_get() { plutil -extract "$1" raw -o - "$2" 2>/dev/null || true; }

# Resolve a possibly-bare program name the way launchd will: against the plist's own PATH.
resolve_prog() {
    local prog="$1" plist="$2" path_env d
    case "$prog" in */*) printf '%s\n' "$prog"; return ;; esac
    path_env="$(plist_get EnvironmentVariables.PATH "$plist")"
    [ -n "$path_env" ] || path_env="/usr/bin:/bin:/usr/sbin:/sbin"
    local IFS=:
    for d in $path_env; do
        [ -x "$d/$prog" ] && { printf '%s\n' "$d/$prog"; return; }
    done
    printf '%s\n' "$prog"
}

realpath_of() { /usr/bin/python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null || printf '%s\n' "$1"; }

# Emits: label<TAB>origin<TAB>declared_path<TAB>realpath   (one line per interpreter to probe)
discover() {
    local plist label n i prog rest_start a real origin
    for plist in "$AGENT_DIR"/*.plist; do
        [ -f "$plist" ] || continue
        # Scope: only jobs that actually touch the guarded subtree. Plists are XML text.
        grep -q "$GUARDED_ROOT" "$plist" 2>/dev/null || continue
        label="$(plist_get Label "$plist")"; [ -n "$label" ] || label="$(basename "$plist" .plist)"
        n="$(plist_get ProgramArguments "$plist")"
        case "$n" in ''|*[!0-9]*) continue ;; esac

        i=0
        prog="$(plist_get "ProgramArguments.$i" "$plist")"
        # /usr/bin/env is an exec trampoline, not a reader: step past it and its VAR=value prefixes.
        if [ "$(basename "$prog")" = "env" ]; then
            i=1
            while [ "$i" -lt "$n" ]; do
                a="$(plist_get "ProgramArguments.$i" "$plist")"
                case "$a" in [A-Za-z_]*=*) i=$((i+1)) ;; *) break ;; esac
            done
            prog="$(plist_get "ProgramArguments.$i" "$plist")"
        fi
        prog="$(resolve_prog "$prog" "$plist")"
        rest_start=$((i+1))

        if is_platform_binary "$prog"; then
            # A platform binary can never hold a Documents grant (that is INV-9's rule, enforced
            # elsewhere). What matters HERE is the non-platform interpreter such a wrapper shells out
            # to -- e.g. com.ea.media-pull is /bin/bash + a wrapper that runs Homebrew node. Scan the
            # script argument for absolute executables rather than hardcoding that knowledge.
            while [ "$rest_start" -lt "$n" ]; do
                a="$(plist_get "ProgramArguments.$rest_start" "$plist")"
                rest_start=$((rest_start+1))
                [ -f "$a" ] && [ -r "$a" ] || continue
                grep -oE '/(opt|Users)/[A-Za-z0-9_./+-]+' "$a" 2>/dev/null | sort -u | while IFS= read -r cand; do
                    [ -f "$cand" ] && [ -x "$cand" ] || continue
                    is_platform_binary "$cand" && continue
                    # Only real executables, not sibling shell scripts a wrapper happens to mention:
                    # a script cannot hold a TCC grant, the binary that runs it does.
                    head -c 2 "$cand" 2>/dev/null | grep -q '#!' && continue
                    printf '%s\t%s\t%s\t%s\n' "$label" "wrapper:$(basename "$a")" "$cand" "$(realpath_of "$cand")"
                done
            done
        else
            [ -x "$prog" ] || { printf '%s\t%s\t%s\t%s\n' "$label" "plist(MISSING)" "$prog" "MISSING"; continue; }
            origin="plist"
            printf '%s\t%s\t%s\t%s\n' "$label" "$origin" "$prog" "$(realpath_of "$prog")"
        fi
    done
}

# ---------------------------------------------------------------------------------------------
# The empirical probe: make the interpreter itself open() a file under the guarded root. This tests
# the thing that actually matters instead of trusting a TCC.db row, survives schema changes, and
# needs no read of a protected database.
# ---------------------------------------------------------------------------------------------
# A probe MUST be bounded. MEASURED 2026-08-14 from launchd: an ungranted interpreter asking for
# ~/Documents does not get a quick EPERM - tccd simply never answers and the process blocks forever
# (observed 2.5+ min before it was killed; the same binary at the same path returns instantly from a
# terminal, so this is TCC attribution, not Gatekeeper). So an indefinite hang IS a drift symptom -
# a real service would hang exactly the same way at startup - and an unbounded probe would wedge this
# job every night. macOS ships no `timeout`/`gtimeout`, hence this watchdog.
PROBE_TIMEOUT="${TCC_CHECK_PROBE_TIMEOUT:-20}"
RUN_OUT=""
run_limited() {
    local secs="$1"; shift
    local pid ticks=0 max rc=0
    max=$((secs * 5))
    RUN_OUT="$(mktemp -t tcc-probe)"
    "$@" >"$RUN_OUT" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null && [ "$ticks" -lt "$max" ]; do sleep 0.2; ticks=$((ticks+1)); done
    if kill -0 "$pid" 2>/dev/null; then
        # TERM first, KILL only as a last resort: SIGKILLing a client that is parked in a TCC
        # request is what wedged the session's tccd during development. A blocked probe means the
        # machine is already in the alarm state, but there is no reason to make it worse.
        kill -TERM "$pid" 2>/dev/null || true
        local grace=0
        while kill -0 "$pid" 2>/dev/null && [ "$grace" -lt 15 ]; do sleep 0.2; grace=$((grace+1)); done
        kill -9 "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        return 124
    fi
    wait "$pid" || rc=$?
    return "$rc"
}

probe() {
    local bin="$1" what="${2:-$TARGET}" out rc=0 kind
    kind="$(basename "$bin")"
    case "$kind" in
        node|node*)
            run_limited "$PROBE_TIMEOUT" "$bin" -e 'require("fs").readFileSync(process.argv[1]);console.log("TCC_PROBE_OK")' "$what" || rc=$?
            ;;
        python|python[0-9]*|python3.*)
            run_limited "$PROBE_TIMEOUT" "$bin" -c 'import sys;open(sys.argv[1],"rb").read(1);print("TCC_PROBE_OK")' "$what" || rc=$?
            ;;
        *)
            printf 'UNPROBED\tno probe recipe for interpreter kind "%s"\n' "$kind"; return 0
            ;;
    esac
    out="$(cat "$RUN_OUT" 2>/dev/null || true)"; rm -f "$RUN_OUT" 2>/dev/null || true
    if [ "$rc" = "124" ]; then
        printf 'BLOCKED\tno answer from tccd in %ss (killed) - this path holds no grant; a real service would HANG here\n' "$PROBE_TIMEOUT"
        return 0
    fi
    if [ "$rc" = "0" ] && printf '%s' "$out" | grep -q TCC_PROBE_OK; then
        printf 'OK\t\n'; return 0
    fi
    # Distinguish a TCC denial from a broken interpreter / missing file: only the former is drift.
    if printf '%s' "$out" | grep -qE 'Operation not permitted|EPERM|PermissionError|Errno 1[^0-9]|EACCES|Permission denied'; then
        printf 'DENIED\t%s\n' "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
    else
        printf 'ERROR\t%s\n' "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
    fi
}

# NOTE ON A REJECTED SIMULATION DESIGN (2026-08-14) - do not reinstate it.
# The obvious way to fake drift is to APFS-clone an interpreter to an ungranted path and probe the
# clone. It works, and it is DANGEROUS. From launchd an ungranted binary does not get EPERM; tccd
# opens a request that nobody can answer and the client blocks indefinitely. Killing that client
# leaves the session's tccd prompt queue WEDGED: afterwards the genuinely-granted uv pythons also
# blocked on ~/Documents, and even AppleScript to System Events timed out. Recovery needs a tccd
# restart or a reboot. A self-test must not be able to break the machine it is testing, so the
# simulation below is a pure FIXTURE - it exercises the detector's logic and execs nothing.

# Prove an interpreter actually runs before drawing conclusions from a failed file probe. Without
# this, "binary is broken" and "binary is denied by TCC" look identical.
sanity_run() {
    local bin="$1" rc=0
    case "$(basename "$bin")" in
        node|node*)                     run_limited 20 "$bin" -e 'process.exit(0)' || rc=$? ;;
        python|python[0-9]*|python3.*)  run_limited 20 "$bin" -c 'pass'            || rc=$? ;;
        *) return 0 ;;
    esac
    rm -f "$RUN_OUT" 2>/dev/null || true
    return "$rc"
}

# ---------------------------------------------------------------------------------------------
# Alerting. The channel MUST NOT depend on the grant it reports on: a status row in nexus.db, a
# courier email or an ea-hub page would each be written by one of the very interpreters that just
# lost access -- the alert would die with the thing it was meant to announce. ~/Library/Logs and
# ~/.local/state are outside ~/Documents and writable by plain bash from launchd, so they still work
# in the exact outage this detects.
# ---------------------------------------------------------------------------------------------
record_status() {
    local verdict="$1" checked="$2" failed="$3"
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    printf '%s verdict=%s context=%s checked=%s failed=%s\n' \
        "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$verdict" "$(context_name)" "$checked" "$failed" > "$STATUS_FILE" 2>/dev/null || true
}
raise_alarm() {
    local msg="$1"
    [ "$ALARM_SUPPRESS" = "1" ] && return 0     # fixture runs must not page him
    # Land it in the log INV-1 already tells him to read daily, so one glance covers both host facts.
    printf '%s  *** TCC DRIFT: %s -- run: ~/.dotfiles/scripts/check-tcc-grants.sh --explain\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" >> "$BACKUP_LOG" 2>/dev/null || true
    osascript -e "display notification \"$msg\" with title \"EA: TCC grant drift\" sound name \"Basso\"" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------------------------
baseline_lookup() { [ -f "$BASELINE_FILE" ] && awk -F'\t' -v d="$1" '$1==d{print $2; exit}' "$BASELINE_FILE" || true; }

run_check() {
    local rows moved=0 gone=0 probefail=0 probed=0 newly=0 unprobed=0
    local label origin declared real was users state detail
    echo "==> TCC grant check  (context: $(context_name), PPID=$PPID)"
    echo "    guarding: $GUARDED_ROOT      probe target: $TARGET"

    rows="$(discover)"
    if [ -z "$rows" ]; then
        err "discovered NO interpreters under $AGENT_DIR referencing $GUARDED_ROOT"
        err "that itself is suspicious - the check would be vacuously green"
        record_status "NO-TARGETS" 0 0; return 1
    fi
    # Report COVERAGE explicitly. Several hubs share one interpreter, so a deduped pass/fail list
    # alone would read identically whether five jobs were in scope or one - a silently vacuous green,
    # the very failure mode this script exists to prevent.
    echo "    in scope ($(printf '%s\n' "$rows" | cut -f1 | sort -u | grep -c .) jobs): $(printf '%s\n' "$rows" | cut -f1 | sort -u | tr '\n' ' ')"

    # -----------------------------------------------------------------------------------------
    # DETECTOR 1 (primary, no exec, no TCC.db, cannot hang): has the interpreter MOVED?
    # A grant names an absolute versioned path. `brew upgrade node` / `uv python upgrade` installs
    # to a NEW path and repoints the symlink; the grant stays behind on the old one. Comparing each
    # declared program's realpath against a recorded baseline catches that the night it happens -
    # while the RUNNING services are still fine, because they only re-resolve the binary when they
    # restart. That is the "before it takes them down" window, and it costs one readlink.
    # -----------------------------------------------------------------------------------------
    local newbase; newbase="$(mktemp -t tcc-baseline)"
    while IFS=$'\t' read -r label origin declared real; do
        [ -n "$declared" ] || continue
        users="$(printf '%s\n' "$rows" | awk -F'\t' -v d="$declared" '$3==d{print $1}' | sort -u | tr '\n' ' ')"
        if [ "$real" = "MISSING" ]; then
            gone=$((gone+1))
            err "GONE: $declared"
            err "    the program named by the plist does not exist at all"
            err "    breaks now: $users"
            continue
        fi
        was="$(baseline_lookup "$declared")"
        if [ -z "$was" ]; then
            newly=$((newly+1))
            printf '%s\t%s\n' "$declared" "$real" >> "$newbase"
        elif [ "$was" != "$real" ]; then
            moved=$((moved+1))
            err "MOVED: $declared"
            err "    grant names: $was"
            err "    now resolves: $real"
            err "    A TCC grant does not follow a version bump. These services keep running on the"
            err "    old binary and fail the NEXT time they restart: $users"
            # Deliberately NOT re-baselined: the alert must repeat nightly until the new path is
            # granted and `--accept-baseline` is run. Auto-updating would silence a live outage.
            printf '%s\t%s\n' "$declared" "$was" >> "$newbase"
        else
            printf '%s\t%s\n' "$declared" "$real" >> "$newbase"
        fi
    done <<< "$rows"
    sort -u "$newbase" -o "$newbase" 2>/dev/null || true
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    mv "$newbase" "$BASELINE_FILE" 2>/dev/null || rm -f "$newbase"
    [ "$newly" -gt 0 ] && ok "baselined $newly new interpreter path(s)"

    # -----------------------------------------------------------------------------------------
    # DETECTOR 2 (confirming): does the grant still WORK? Only for paths that did NOT move - those
    # are the ones a grant should already cover, so the probe answers from the TCC database and
    # returns at once. An interpreter at a path with no grant does NOT get a quick EPERM from
    # launchd; tccd never answers and the process blocks (measured 2026-08-14). So probing a path we
    # already know moved would buy nothing and would leave a wedged request behind.
    # -----------------------------------------------------------------------------------------
    while IFS= read -r real; do
        [ -n "$real" ] && [ "$real" != "MISSING" ] || continue
        declared="$(printf '%s\n' "$rows" | awk -F'\t' -v r="$real" '$4==r{print $3; exit}')"
        was="$(baseline_lookup "$declared")"
        [ "$was" = "$real" ] || continue          # moved: reported above, never exec it
        users="$(printf '%s\n' "$rows" | awk -F'\t' -v r="$real" '$4==r{print $1}' | sort -u | tr '\n' ' ')"
        origin="$(printf '%s\n' "$rows" | awk -F'\t' -v r="$real" '$4==r{print $2; exit}')"
        probed=$((probed+1))
        IFS=$'\t' read -r state detail < <(probe "$real")
        case "$state" in
            OK)       ok "$(basename "$real") [$origin] -> readable   (serves: $users)" ;;
            DENIED|BLOCKED)
                      probefail=$((probefail+1))
                      err "$state: $real"
                      err "    breaks: $users"
                      err "    $detail" ;;
            UNPROBED) unprobed=$((unprobed+1)); warn "$detail: $real   (serves: $users)" ;;
            *)        probefail=$((probefail+1))
                      err "probe ERROR on $real (not a clean pass - treating as failure)"
                      err "    breaks: $users"
                      err "    $detail" ;;
        esac
    done <<< "$(printf '%s\n' "$rows" | cut -f4 | sort -u)"

    echo "    moved=$moved gone=$gone probed=$probed probe-failures=$probefail unprobed=$unprobed"

    local bad=$((moved + gone + probefail))
    if [ "$bad" -gt 0 ]; then
        err "TCC GRANT DRIFT DETECTED ($moved moved, $gone missing, $probefail denied)"
        err "Fix: System Settings > Privacy & Security > Files and Folders (or Full Disk Access),"
        err "     add the CURRENT path shown above. Run --explain for the exact grant rows."
        err "     Then re-baseline: $0 --accept-baseline"
        record_status "DRIFT" "$probed" "$bad"
        raise_alarm "$moved moved, $gone missing, $probefail denied - EA services lose $GUARDED_ROOT on next restart"
        return 1
    fi
    # DETECTOR 1 is context-independent (a readlink is a readlink), so a clean move check is a real
    # result even from a terminal. Only DETECTOR 2 needs launchd attribution to mean anything.
    if context_is_launchd; then
        ok "no drift: $probed interpreter(s) unmoved and still reading $GUARDED_ROOT under launchd"
        record_status "OK" "$probed" 0
    else
        ok "no interpreter moved (this part is context-independent and trustworthy here)"
        warn "the $probed access probe(s) passed, but this context inherited its parent's TCC grant,"
        warn "so they prove nothing on their own. Authoritative: --verify-via-launchd"
        record_status "OK-MOVE-ONLY" "$probed" 0
    fi
    return 0
}

# Fixture-based self-test: build a throwaway LaunchAgents dir + baseline that DESCRIBE a drifted
# machine, then run the real detector against them. It proves the detector fires (and that it still
# passes the healthy leg in the same breath) without cloning a binary or provoking a single TCC
# request, so it is safe to run any time, in any context - unlike the design it replaced.
write_fixture_plist() {
    local dir="$1" label="$2" prog="$3"
    cat > "$dir/$label.plist" <<FIXTURE_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$label</string>
    <key>ProgramArguments</key>
    <array><string>$prog</string><string>-e</string><string>0</string></array>
    <key>EnvironmentVariables</key>
    <dict><key>FIXTURE_ROOT</key><string>$GUARDED_ROOT/EA</string></dict>
</dict>
</plist>
FIXTURE_EOF
}

do_simulate_drift() {
    local fixdir fixstate real_node rc=0
    real_node="$(realpath_of /opt/homebrew/bin/node)"
    if [ ! -x "$real_node" ]; then err "simulation needs a real node to point at"; exit 1; fi
    fixdir="$(mktemp -d -t tcc-fixture-agents)"; fixstate="$(mktemp -d -t tcc-fixture-state)"

    # 1. MOVED: a live, existing interpreter whose baseline records a DIFFERENT (older) real path -
    #    exactly the state `brew upgrade node` leaves behind.
    write_fixture_plist "$fixdir" "com.fixture.moved" "/opt/homebrew/bin/node"
    printf '%s\t%s\n' "/opt/homebrew/bin/node" "/opt/homebrew/Cellar/node/22.0.0/bin/node" > "$fixstate/baseline"
    # 2. GONE: a plist naming a program that does not exist.
    write_fixture_plist "$fixdir" "com.fixture.gone" "/opt/homebrew/Cellar/node/9.9.9/bin/node"
    # 3. HEALTHY control: same real interpreter, baseline agrees - must still pass, so the fixture
    #    cannot "detect drift" by simply failing everything.
    write_fixture_plist "$fixdir" "com.fixture.healthy" "$real_node"
    printf '%s\t%s\n' "$real_node" "$real_node" >> "$fixstate/baseline"

    echo "==> SIMULATED DRIFT (fixture: nothing is exec'd at an ungranted path, tccd is not touched)"
    echo "    pretending /opt/homebrew/bin/node was granted at Cellar/node/22.0.0 and has since moved"
    (
        AGENT_DIR="$fixdir"; STATE_DIR="$fixstate"
        BASELINE_FILE="$fixstate/baseline"; STATUS_FILE="$fixstate/status"
        BACKUP_LOG="$fixstate/alarm.log"; ALARM_SUPPRESS=1
        run_check
    ) || rc=$?
    echo "    (fixture run exited $rc)"
    rm -rf "$fixdir" "$fixstate"
    if [ "$rc" != "0" ]; then
        ok "SELF-TEST PASSED: the detector reported drift on the fixture and exited non-zero"
        return 0
    fi
    err "SELF-TEST FAILED: the detector saw a moved + a missing interpreter and still said OK."
    err "This checker cannot be trusted - fix it before relying on the nightly run."
    return 1
}

do_accept_baseline() {
    local rows n=0 tmp label origin declared real
    rows="$(discover)"
    [ -n "$rows" ] || { err "discovered nothing to baseline"; exit 1; }
    tmp="$(mktemp -t tcc-baseline)"
    while IFS=$'\t' read -r label origin declared real; do
        [ -n "$declared" ] && [ "$real" != "MISSING" ] || continue
        printf '%s\t%s\n' "$declared" "$real" >> "$tmp"; n=$((n+1))
    done <<< "$rows"
    sort -u "$tmp" -o "$tmp"
    mkdir -p "$STATE_DIR"; mv "$tmp" "$BASELINE_FILE"
    ok "baseline accepted: $(grep -c . "$BASELINE_FILE") path(s) recorded as current"
    warn "only do this AFTER granting the new paths, or you have silenced a live outage"
}

# ---------------------------------------------------------------------------------------------
# Isolation diagnostic. Three sub-probes per interpreter, so a failure cannot be blamed on the wrong
# thing: START (no file access at all), CTRL (a file OUTSIDE the guarded root - unprotected by TCC),
# and DOCS (the guarded root). Only "START ok + CTRL ok + DOCS not ok" is a TCC verdict; anything
# else means the interpreter itself, or the harness, is the problem.
# ---------------------------------------------------------------------------------------------
CONTROL_FILE="${TCC_CHECK_CONTROL:-/etc/hosts}"
run_diag() {
    local rows real users t0 state detail
    echo "==> TCC isolation diagnostic  (context: $(context_name), PPID=$PPID)"
    echo "    START = interpreter starts, no file access"
    echo "    CTRL  = reads $CONTROL_FILE (outside $GUARDED_ROOT, no TCC involved)"
    echo "    DOCS  = reads $TARGET"
    rows="$(discover)"
    while IFS= read -r real; do
        [ -n "$real" ] && [ "$real" != "MISSING" ] || continue
        users="$(printf '%s\n' "$rows" | awk -F'\t' -v r="$real" '$4==r{print $1}' | sort -u | tr '\n' ' ')"
        echo "--- $real"
        echo "    serves: $users"

        t0=$SECONDS
        if sanity_run "$real"; then echo "    START ok   ($((SECONDS-t0))s)"; else echo "    START FAIL ($((SECONDS-t0))s)"; fi

        t0=$SECONDS
        IFS=$'\t' read -r state detail < <(probe "$real" "$CONTROL_FILE")
        echo "    CTRL  $state   ($((SECONDS-t0))s) ${detail:0:80}"

        t0=$SECONDS
        IFS=$'\t' read -r state detail < <(probe "$real" "$TARGET")
        echo "    DOCS  $state   ($((SECONDS-t0))s) ${detail:0:80}"
    done <<< "$(printf '%s\n' "$rows" | cut -f4 | sort -u)"
    record_status "DIAG" 0 0
}

# ---------------------------------------------------------------------------------------------
# Secondary diagnostic: explains WHY, by naming the stale grant. Read-only, best-effort - the
# databases need Full Disk Access, which a launchd-run bash does not have, so this is the by-hand
# companion to the probe rather than part of the verdict.
# ---------------------------------------------------------------------------------------------
do_explain() {
    echo "==> TCC grant inventory (read-only; explains WHICH path a grant is pinned to)"
    command -v sqlite3 >/dev/null 2>&1 || { err "sqlite3 not found"; exit 1; }
    local db out any=0
    for db in "$HOME/Library/Application Support/com.apple.TCC/TCC.db" "/Library/Application Support/com.apple.TCC/TCC.db"; do
        echo "--- $db"
        out="$(sqlite3 "file:${db// /%20}?mode=ro" \
              "select service||'|'||client||'|'||auth_value from access where client_type=1 and service in ('kTCCServiceSystemPolicyDocumentsFolder','kTCCServiceSystemPolicyAllFiles');" 2>&1)" || {
            warn "unreadable (needs Full Disk Access for THIS process): $(printf '%s' "$out" | head -1)"; continue; }
        any=1
        if [ -z "$out" ]; then warn "no path-keyed grants"; continue; fi
        while IFS='|' read -r svc client auth; do
            [ -n "$client" ] || continue
            if [ -e "$client" ]; then
                ok "$(basename "$client") auth=$auth  $svc"
                echo "        path exists: $client"
            else
                err "STALE GRANT (path no longer exists): $client"
                err "        $svc auth=$auth - whatever replaced this binary holds NO grant"
            fi
        done <<< "$out"
    done
    [ "$any" = "1" ] || { err "could not read either TCC.db - run this from Terminal (it has Full Disk Access)"; exit 1; }

    echo "--- discovered interpreters vs. those grants"
    local label origin declared real
    while IFS=$'\t' read -r label origin declared real; do
        [ -n "$label" ] || continue
        echo "    $label [$origin]"
        echo "        declared: $declared"
        echo "        real    : $real"
    done <<< "$(discover)"
    echo "    (a grant must name the REAL path; the declared path is only a symlink into it)"
}

# ---------------------------------------------------------------------------------------------
do_verify_via_launchd() {
    local uid before after waited=0 verdict
    uid="$(id -u)"
    launchctl print "gui/$uid/$LABEL" >/dev/null 2>&1 || {
        err "$LABEL is not loaded - the authoritative check cannot run."
        err "Install it first: $0 --install-launchagent"; exit 1; }
    mkdir -p "$STATE_DIR"
    case "${1:-}" in
        --simulate) echo simulate > "$REQUEST_FILE"; echo "==> requesting a SIMULATION run" ;;
        --diag)     echo diag     > "$REQUEST_FILE"; echo "==> requesting an ISOLATION DIAGNOSTIC run" ;;
    esac
    # Wait for the status file to REAPPEAR rather than to differ from its old contents. Diffing
    # against a saved copy silently returns the STALE verdict whenever a run is slow or dies, which
    # is how an unfinished simulation once got reported as a pass. Absence is unambiguous.
    before=""
    [ -f "$STATUS_FILE" ] && before="$(cat "$STATUS_FILE")"
    rm -f "$STATUS_FILE" 2>/dev/null || true
    echo "==> kickstarting $LABEL (runs under launchd = the services' own TCC attribution)"
    launchctl kickstart -k "gui/$uid/$LABEL" >/dev/null 2>&1 || true
    echo -n "    waiting"
    while [ "$waited" -lt 300 ]; do
        if [ -f "$STATUS_FILE" ]; then break; fi
        sleep 1; waited=$((waited+1))
        [ $((waited % 5)) -eq 0 ] && echo -n "."
    done
    echo ""
    rm -f "$REQUEST_FILE" 2>/dev/null || true
    after=""
    [ -f "$STATUS_FILE" ] && after="$(cat "$STATUS_FILE")"
    if [ -z "$after" ]; then
        [ -n "$before" ] && printf '%s\n' "$before" > "$STATUS_FILE"
        err "no result after ${waited}s - the run produced no verdict."
        err "Check ~/Library/Logs/tcc-drift.log (a wedged probe is itself a finding)."
        exit 1
    fi
    echo "==> authoritative result (from launchd):"
    echo "    $after"
    verdict="$(printf '%s' "$after" | sed -n 's/.*verdict=\([A-Za-z-]*\).*/\1/p')"
    echo "    full log: ~/Library/Logs/tcc-drift.log"
    case "$verdict" in
        OK|SIM-DETECTOR-WORKS) ok "verdict: $verdict"; return 0 ;;
        *) err "verdict: $verdict - see the log above"; return 1 ;;
    esac
}

do_install_launchagent() {
    local self plist uid
    self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    plist="$AGENT_DIR/$LABEL.plist"
    uid="$(id -u)"
    case "$self" in "$HOME/Documents"/*)
        err "this script sits under ~/Documents; /bin/bash could not open it from launchd (INV-9)"; exit 1 ;;
    esac
    mkdir -p "$AGENT_DIR" "$STATE_DIR"
    cat > "$plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- GENERATED by dotfiles/scripts/check-tcc-grants.sh --install-launchagent. Daily TCC grant-drift
     check. It MUST run from launchd: only here does TCC attribute file access to the exec'd
     interpreter itself, the same way it does for the services this guards. /bin/bash is a platform
     binary and the script lives outside ~/Documents, per INV-9. -->
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$self</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key><string>$HOME</string>
        <key>PATH</key><string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>StartCalendarInterval</key>
    <dict><key>Hour</key><integer>3</integer><key>Minute</key><integer>25</integer></dict>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>$HOME/Library/Logs/tcc-drift.log</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/tcc-drift.log</string>
</dict>
</plist>
PLIST_EOF
    launchctl bootout "gui/$uid/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$uid" "$plist" 2>/dev/null || true
    # Verify it is actually loaded: an install that "succeeds" with the job unloaded is a silent gap,
    # which is the exact class of failure this script exists to prevent.
    if launchctl print "gui/$uid/$LABEL" >/dev/null 2>&1; then
        ok "installed + loaded $LABEL (daily 03:25; log ~/Library/Logs/tcc-drift.log)"
        ok "on-demand: $0 --verify-via-launchd"
    else
        err "wrote $plist but $LABEL is NOT loaded - drift detection is INACTIVE."
        err "Retry: launchctl bootstrap gui/$uid '$plist' ; then launchctl print gui/$uid/$LABEL"
        exit 1
    fi
}

# A launchd run honours a one-shot request left by --verify-via-launchd --simulate.
launchd_requested_mode() {
    local m=normal
    if context_is_launchd && [ -f "$REQUEST_FILE" ]; then
        m="$(cat "$REQUEST_FILE" 2>/dev/null || echo normal)"
        rm -f "$REQUEST_FILE" 2>/dev/null || true
    fi
    printf '%s\n' "$m"
}

case "${1:-}" in
    "")  case "$(launchd_requested_mode)" in
             simulate) do_simulate_drift ;;
             diag)     run_diag ;;
             *)        run_check ;;
         esac ;;
    --simulate-drift)        do_simulate_drift ;;
    --diag)                  run_diag ;;
    --accept-baseline)       do_accept_baseline ;;
    --verify-via-launchd)    do_verify_via_launchd "${2:-}" ;;
    --explain)               do_explain ;;
    --install-launchagent)   do_install_launchagent ;;
    *) err "unknown arg '$1'"
       echo "usage: check-tcc-grants.sh [--verify-via-launchd [--simulate|--diag]|--simulate-drift|--diag|--explain|--accept-baseline|--install-launchagent]" >&2
       exit 2 ;;
esac
