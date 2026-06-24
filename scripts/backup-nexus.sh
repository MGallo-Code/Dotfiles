#!/usr/bin/env bash
# backup-nexus.sh  --  host-authoritative backup of the live nexus.db (remote-hubs Phase D).
#
# Once nexus.db leaves git (Phase-D cutover), the host is the SINGLE source of truth and git is no
# longer the backstop. This script is that backstop: a consistent online backup + an integrity gate +
# the data/secret vet that EA's CI check-no-secrets.py used to run on the tracked nexus.db (which goes
# CI-dark once untracked). Rotates into a directory OUTSIDE any repo, with N-day retention.
#
# Usage:
#   backup-nexus.sh                      take one backup (integrity-gated + vetted), prune old ones
#   backup-nexus.sh --restore-drill      backup, THEN restore it to a temp DB and prove it opens with
#                                        matching tables/rowcounts (run this BEFORE untracking nexus.db)
#   backup-nexus.sh --install-launchagent  write + load com.ea.nexus-backup (daily) on the macOS host
#
# Env overrides:  NEXUS_DB, NEXUS_BACKUP_DIR, NEXUS_BACKUP_RETENTION_DAYS
set -euo pipefail

DB="${NEXUS_DB:-$HOME/Documents/EA/nexus/nexus.db}"
BACKUP_DIR="${NEXUS_BACKUP_DIR:-$HOME/.local/state/nexus-backups}"   # OUTSIDE any repo (not git-tracked)
RETENTION_DAYS="${NEXUS_BACKUP_RETENTION_DAYS:-30}"
LABEL="com.ea.nexus-backup"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}\xe2\x9c\x93${NC} $*"; }
warn() { echo -e "  ${YELLOW}!${NC} $*"; }
err()  { echo -e "  ${RED}\xe2\x9c\x97${NC} $*" >&2; }

require() {
    command -v sqlite3 >/dev/null 2>&1 || { err "sqlite3 not found - cannot back up nexus.db"; exit 1; }
    [ -f "$DB" ] || { err "nexus.db not found at $DB"; exit 1; }
}

# The data/secret vet: faithful port of EA scripts/ci/check-no-secrets.py scan_sqlite (SOURCE OF
# TRUTH there). Flags a secret-named table/column OR unambiguous key material in a TEXT value. PII
# (notes, names) must NOT trip - only the unambiguous credential shapes. Opens the target READ-ONLY.
# Exit 0 clean, 2 vet-skipped (python3 absent - NOT clean), 3 found, 4 could-not-open (fail closed). Keep
# the regexes in lockstep with check-no-secrets.py.
vet_db() {
    local target="$1"
    # python3 absent -> return a DISTINCT "skipped" code (2), NOT 0. Returning 0 made do_backup print "vet
    # clean" for a scan that never ran - fail-OPEN, contradicting the fail-closed contract (cross-check).
    command -v python3 >/dev/null 2>&1 || { warn "python3 not found - SKIPPING the data/secret vet (install python3 on the host)"; return 2; }
    python3 - "$target" <<'PYVET'
import re, sqlite3, sys

target = sys.argv[1]
# Mirror of EA check-no-secrets.py FORBIDDEN_DB_NAME + DB_VALUE_PATTERNS (keep in lockstep).
FORBIDDEN_DB_NAME = re.compile(r"(?i)(credential|secret|password|oauth|refresh_token|access_token|api[_-]?key)")
DB_VALUE_PATTERNS = [
    ("private key block", re.compile(r"-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----")),
    ("Slack token", re.compile(r"\bxox[baprs]-[0-9A-Za-z-]{10,}")),
    ("GitHub token", re.compile(r"\bgh[pousr]_[0-9A-Za-z]{36,}")),
    ("Anthropic key", re.compile(r"\bsk-ant-[0-9A-Za-z_-]{20,}")),
    ("OpenAI key", re.compile(r"\bsk-(?:proj-)?[0-9A-Za-z]{20,}")),
    ("Google OAuth client secret", re.compile(r"\bGOCSPX-[0-9A-Za-z_-]{20,}")),
    ("JWT", re.compile(r"\beyJ[0-9A-Za-z_-]{10,}\.[0-9A-Za-z_-]{10,}\.[0-9A-Za-z_-]{10,}")),
]
findings = []
try:
    con = sqlite3.connect("file:" + target.replace("\\", "/") + "?mode=ro", uri=True)
except Exception as e:
    print(f"  could not open backup read-only for vetting ({e})", file=sys.stderr)
    sys.exit(4)
try:
    cur = con.cursor()
    cur.execute("SELECT name FROM sqlite_master WHERE type='table'")
    for (t,) in cur.fetchall():
        if FORBIDDEN_DB_NAME.search(t):
            findings.append(f"secret-named table '{t}'")
        try:
            cur.execute(f"PRAGMA table_info('{t}')")
            cols = [r[1] for r in cur.fetchall()]
        except Exception:
            cols = []
        for c in cols:
            if FORBIDDEN_DB_NAME.search(c):
                findings.append(f"secret-named column '{t}.{c}'")
        if not cols:
            continue
        try:
            cur.execute("SELECT " + ", ".join('"' + c + '"' for c in cols) + f" FROM '{t}'")
            for row in cur.fetchall():
                for val in row:
                    if isinstance(val, str):
                        for name, pat in DB_VALUE_PATTERNS:
                            if pat.search(val):
                                findings.append(f"{name} in table '{t}'")
        except Exception:
            continue
finally:
    con.close()
if findings:
    for f in sorted(set(findings)):
        print("  FINDING: " + f, file=sys.stderr)
    sys.exit(3)
PYVET
}

do_backup() {
    require
    mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR" 2>/dev/null || true
    local ts dest tmp
    ts="$(date +%Y%m%d-%H%M%S)"
    dest="$BACKUP_DIR/nexus-$ts.db"
    tmp="$(mktemp "$BACKUP_DIR/.nexus-backup.XXXXXX")"

    # Clean up the temp (+ any sidecars) on ANY exit from here on, so a mid-backup failure never leaves a
    # stray .nexus-backup.* in the backup dir. Cleared right after a successful mv (the temp is gone then).
    cleanup_tmp() { rm -f "$tmp" "$tmp"-wal "$tmp"-shm 2>/dev/null; }
    trap cleanup_tmp EXIT

    # Online .backup: consistent even while the live WAL DB is in use. The filename MUST be inside the
    # dot-command quotes - `sqlite3 db ".backup" file` is INVALID and silently backs up nothing useful.
    if ! sqlite3 "$DB" ".backup main '$tmp'"; then err "sqlite3 .backup failed (source malformed?)"; exit 1; fi

    # Convert the snapshot to a rollback journal so the ARCHIVE is one self-contained file (the .backup
    # inherits the source's WAL mode, which would otherwise leave -wal/-shm sidecars next to it).
    sqlite3 "$tmp" 'PRAGMA journal_mode=DELETE;' >/dev/null || { err "could not finalize backup journal mode"; exit 1; }

    # Integrity gate: treat BOTH a non-zero exit AND output != "ok" as failure (never rotate a corrupt
    # backup into place).
    local out
    out="$(sqlite3 "$tmp" 'PRAGMA integrity_check;')" || { err "integrity_check failed to run"; exit 1; }
    if [ "$out" != "ok" ]; then err "integrity_check returned: $out"; exit 1; fi

    # Non-emptiness gate: integrity_check returns "ok" even for a 0-table/empty DB, so ALSO require the
    # backup's table set to match the live source (a truncated/empty .backup would otherwise pass).
    local src_tc dst_tc
    src_tc="$(sqlite3 "$DB"  "SELECT count(*) FROM sqlite_master WHERE type='table';")" || { err "could not count source tables"; exit 1; }
    dst_tc="$(sqlite3 "$tmp" "SELECT count(*) FROM sqlite_master WHERE type='table';")" || { err "could not count backup tables"; exit 1; }
    if [ "${dst_tc:-0}" -lt 1 ] || [ "$dst_tc" != "$src_tc" ]; then
        err "backup has $dst_tc table(s), source has $src_tc - empty/truncated backup, refusing to rotate it in"; exit 1
    fi

    rm -f "$tmp"-wal "$tmp"-shm    # defensive: drop any transient sidecars before rotating into place
    chmod 600 "$tmp"; mv "$tmp" "$dest"
    trap - EXIT                    # temp is now $dest; nothing to clean
    ok "backup written: $dest ($(du -h "$dest" 2>/dev/null | cut -f1)); integrity ok"

    # Retention: prune backups older than N days.
    find "$BACKUP_DIR" -name 'nexus-*.db' -type f -mtime +"$RETENTION_DAYS" -delete 2>/dev/null || true

    # Data/secret vet on the just-made backup (the good backup is kept regardless; we still ALERT loud).
    local vrc=0
    vet_db "$dest" || vrc=$?
    if [ "$vrc" = "0" ]; then
        ok "data/secret vet clean (no credential-named table/column, no key material)"
    elif [ "$vrc" = "2" ]; then
        warn "data/secret vet SKIPPED (python3 absent) - NOT verified clean; install python3 on the host to enable it"
        # ALSO to stderr: the no-arg/LaunchAgent path runs `do_backup >/dev/null` (and the restore drill
        # pipes `do_backup | tail -1`), both of which would swallow the stdout warn - so the "NOT verified
        # clean" signal would vanish on a python3-less host. stderr survives both (cross-check).
        echo "  ! nexus backup: data/secret vet SKIPPED (python3 absent) - NOT verified clean" >&2
    elif [ "$vrc" = "3" ]; then
        err "SECURITY: nexus.db backup carries credential-shaped content (see FINDINGs above) - investigate."
        err "The backup at $dest is kept, but nexus.db appears to hold a live secret (an INV-1-class regression)."
        exit 3
    else
        err "data/secret vet could not run cleanly (rc=$vrc) - treating as fail-closed; check $dest by hand."
        exit "$vrc"
    fi
    echo "$dest"
}

# Restore drill: prove a backup is RESTORABLE + COMPLETE, not just writable. Validation is INTRINSIC to
# the restored backup - integrity + every key data-class table present + a non-trivial TOTAL rowcount -
# NOT a comparison to the LIVE DB. (Cross-vendor cross-check: comparing to the live DB at a later time is
# racy - a concurrent write makes a valid backup mismatch; and checking only `contacts` would pass a
# backup that lost tasks/sessions/invoices/email rows. So check the data classes the runbook says nexus
# holds, intrinsically.)
do_restore_drill() {
    require
    echo "==> nexus restore drill"
    local dest; dest="$(do_backup | tail -1)"
    local restore; restore="$(mktemp -t nexus-restore.XXXXXX)"
    # The restore temp (a 0600 copy of nexus.db) is rm'd on EVERY path below - each error guard rms it and
    # the success path rms it before the verdict. (Deliberately NO `trap ... EXIT`: it fires at top-level
    # exit where the function-local `restore` is already out of scope and would trip `set -u` with an
    # 'unbound variable' - cross-check found exactly that. A SIGINT mid-drill leaves one transient $TMPDIR
    # copy the OS reclaims; acceptable for an interactive operator action.)
    # Restore = copy the backup file and open it fresh (a SQLite .db backup IS the full DB).
    cp "$dest" "$restore"
    local rout; rout="$(sqlite3 "$restore" 'PRAGMA integrity_check;')" || { err "restored copy failed integrity_check to run"; rm -f "$restore" "$restore"-wal "$restore"-shm; exit 1; }
    [ "$rout" = "ok" ] || { err "restored copy integrity_check: $rout"; rm -f "$restore" "$restore"-wal "$restore"-shm; exit 1; }

    # Completeness: the restored copy must contain EVERY table the LIVE source has, and the TOTAL rows
    # must be non-trivial. A table-NAME-set compare to the live DB is race-free under ROW writes (the
    # schema is stable under inserts/updates - only row COUNTS would race); it is NOT race-free under a
    # concurrent schema MIGRATION (a DDL add between the .backup snapshot and this live-schema read would
    # spuriously fail a valid backup - but in the SAFE direction, never a false PASS, and the RUNBOOK
    # quiesces writers before the drill). This replaces a
    # hardcoded data-class subset (contacts/tasks/sessions/invoices/email_actions) that silently ignored
    # meetings/payments/exercises/projects - an incomplete subset would PASS a lossy backup (cross-check).
    local restore_tables src_tables total=0 missing="" t c ntables
    restore_tables="$(sqlite3 "$restore" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';")" \
        || { err "restore drill: could not read restored schema"; rm -f "$restore" "$restore"-wal "$restore"-shm; exit 1; }
    src_tables="$(sqlite3 "$DB" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';")" \
        || { err "restore drill: could not read source schema for the completeness check"; rm -f "$restore" "$restore"-wal "$restore"-shm; exit 1; }
    # Iterate with a while-read over the NEWLINE-separated lists + a fixed-string grep, so a future table
    # whose name contains a space or a regex metachar can't word-split or mis-match (cross-check: the old
    # `for t in $restore_tables` + `grep -qx` was correct only because today's 18 tables are plain
    # snake_case).
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        c="$(sqlite3 "$restore" "SELECT count(*) FROM \"$t\";" 2>/dev/null || echo 0)"
        total=$((total + c))
    done <<< "$restore_tables"
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        printf '%s\n' "$restore_tables" | grep -Fqx -- "$t" || missing="$missing $t"
    done <<< "$src_tables"
    # Reverse check: the restored copy must ALSO have no EXTRA tables the source lacks - a faithful
    # `.backup` can't add tables, but a corrupt backup process could, and the set must match EXACTLY
    # (cross-check: the forward-only check would pass a backup with spurious/junk tables).
    local extra=""
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        printf '%s\n' "$src_tables" | grep -Fqx -- "$t" || extra="$extra $t"
    done <<< "$restore_tables"
    ntables="$(printf '%s\n' "$restore_tables" | grep -c . || true)"
    rm -f "$restore" "$restore"-wal "$restore"-shm    # temp consumed; rm before the verdict (all paths)

    if [ -n "$missing" ]; then
        err "restore drill FAILED: restored copy is missing source table(s):$missing (data lost in backup)"; exit 1
    fi
    if [ -n "$extra" ]; then
        err "restore drill FAILED: restored copy has UNEXPECTED table(s) not in the source:$extra (backup corruption?)"; exit 1
    fi
    if [ "$total" -lt 1 ]; then
        err "restore drill FAILED: restored copy has $ntables tables but 0 total rows (empty/truncated backup)"; exit 1
    fi
    ok "restore drill PASSED: restored copy opens, integrity ok, $ntables tables, $total total rows, every source table present"
    echo "==> restore drill complete"
}

do_install_launchagent() {
    [ "$(uname -s)" = "Darwin" ] || { err "the nexus-backup LaunchAgent is macOS-only (this is $(uname -s))"; exit 1; }
    local self plist uid
    self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    plist="$HOME/Library/LaunchAgents/$LABEL.plist"
    uid="$(id -u)"
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- GENERATED by dotfiles/scripts/backup-nexus.sh --install-launchagent. Daily host-side nexus.db
     backup + integrity + data/secret vet (remote-hubs Phase D). -->
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
    <dict><key>Hour</key><integer>3</integer><key>Minute</key><integer>30</integer></dict>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>$HOME/Library/Logs/nexus-backup.log</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/nexus-backup.log</string>
</dict>
</plist>
PLIST_EOF
    launchctl bootout "gui/$uid/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$uid" "$plist" 2>/dev/null || true
    # VERIFY the job is actually loaded (don't trust bootstrap's rc - it can be flaky). After nexus.db
    # leaves git this LaunchAgent is the ONLY INV-1 / backup backstop, so an install that "succeeds" while
    # the job is NOT loaded is a silent gap - fail LOUD (exit 1) instead of just warning (cross-check).
    if launchctl print "gui/$uid/$LABEL" >/dev/null 2>&1; then
        ok "installed + loaded $LABEL (daily 03:30; logs ~/Library/Logs/nexus-backup.log)"
    else
        err "wrote $plist but $LABEL is NOT loaded - the daily backup backstop is INACTIVE."
        err "Retry: launchctl bootstrap gui/$uid '$plist' ; then launchctl print gui/$uid/$LABEL"
        exit 1
    fi
}

case "${1:-}" in
    "")                     do_backup >/dev/null && ok "nexus backup complete" ;;
    --restore-drill)        do_restore_drill ;;
    --install-launchagent)  do_install_launchagent ;;
    *) err "unknown arg '$1'"; echo "usage: backup-nexus.sh [--restore-drill|--install-launchagent]" >&2; exit 2 ;;
esac
