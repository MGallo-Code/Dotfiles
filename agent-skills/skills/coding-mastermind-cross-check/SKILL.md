---
name: coding-mastermind-cross-check
description: Runs a rare, high-stakes decision or diff past other-vendor flagship CLIs (Codex, Gemini) in read-only/sandboxed mode, prompting them to REFUTE it, then synthesizes one PROPOSAL that preserves the disagreement. Adversarial cross-check, NOT a majority vote. Use only for high-stakes or large-diff or strategic decisions; skip on Q&A and small edits.
---

# coding-mastermind-cross-check

## Overview

A second opinion is most valuable when it DISAGREES, so this gets one on purpose. It
packages a concrete claim, decision, or diff and asks other-vendor models to refute it,
not to praise it (which avoids the sycophancy that makes "what do you think?" useless).
Cross-vendor matters: a model is blind to its own failure modes, and a different vendor
surfaces bugs single-model review misses (Arbiter, arXiv:2603.08993, found a real
Gemini-CLI memory bug for $0.27 that single-model missed). The panel also seats a
FRESH-CONTEXT Claude (the dispatch worker, given the same packaged prompt): the main loop that
WROTE the claim is its worst judge, so a fresh Claude strips that author bias. It is a peer to
the two vendors, not a replacement - cross-vendor stays the PRIMARY diversity (a same-vendor
voice shares some blind spots); the fresh Claude's job is removing the author's bias.

This is the ONE multi-model technique the kit keeps. It explicitly rejects the others:
weight-merging (impossible on hosted models), mixed-model MoA (Self-MoA wins), and
output-voting/ensembling (the "popularity trap" - consensus is not correctness). So do
NOT turn this into a majority vote. The output is a synthesis that PRESERVES the
dissent, never a tally.

## When to Use

- A rare, high-stakes decision (an architecture bet, an auth change, an irreversible
  migration) or a large/strategic diff.
- A claim you want adversarially stress-tested before committing.

**When NOT to use:** Q&A, small edits, anything where one lever already suffices (pick
ONE lever per change-size). The CLIs cost their vendors' tokens and ~30-120s each, so
this is on-demand and interactive only. The scheduled backstop audit must NOT depend on
it (headless auth is unreliable).

## Process

1. **Frame the claim to refute.** Write a tight, self-contained prompt: the exact claim
   or decision, the minimal context to judge it (paste the diff or the key code, do not
   assume the model has the repo, and never say where the code lives: the vendor can read
   any path it is given), and the instruction: "Try to REFUTE this. Find the
   strongest case that it is wrong, unsafe, or will not work. If you cannot, say so and
   why." Ask for a verdict + the single strongest counter-argument, not an essay.
2. **Delegate the dispatch to ONE context-hygiene worker.** The raw multi-model output
   (each model's full answer + CLI metadata) is large and would bloat the rest of this
   session and get re-read every turn. So spawn a SINGLE subagent (Boomerang
   context-hygiene delegation: one worker, motive = context-rot, not parallelism - it
   does NOT violate the convergent/few-agent rule) and pass it the framed prompt
   EXPLICITLY (a fresh worker, not a context-inheriting fork, unless the decision truly
   needs the full conversation). Because the worker is a FRESH-CONTEXT Claude (the fresh worker above, not a
   context-inheriting fork), it is also an INDEPENDENT refuting voice the author lacks: have it
   (a) refute the claim ITSELF from that fresh context - stripping the bias of the main loop
   that wrote the claim - THEN (b) run the vendor CLIs. It is now a refuter on the panel, not
   just a dispatcher, so use a CAPABLE model; the intelligence is in all three replies, not
   only the vendors'.
3. **The worker runs the other-vendor CLIs, read-only/sandboxed, each from a FRESH EMPTY
   temp dir.** Never `--yolo` / `danger-full-access`. macOS has no `timeout`; use `gtimeout`
   or the harness timeout (`vendor_watch` below also stops a run at its deadline).

   **Read-only is not read-blind.** `--sandbox read-only` and `--approval-mode plan` block
   WRITES, not READS: either CLI can still read any absolute path the OS user can, and what it
   reads goes to its vendor. On 2026-10-03 (GalloGrid learning-ui M1 freeze) `codex exec
   --sandbox read-only` started inside the repo read `ea-hub` static files, templates, a test
   grep and `git log`/`git status`, so excerpts reached OpenAI though only a concise summary
   was approved. So, for BOTH CLIs:
   - Start each in its own fresh empty temp dir, never in a repo or any populated dir, and never
     pass `-C <repo>`, `--add-dir` or `--include-directories`.
   - The prompt never says where code lives: no absolute or `~` path, no repo or workspace-root
     name. Paste the code. Repo-relative names inside a pasted diff are fine; with no workspace
     roots loaded and no read tools they point at nothing.
   - Load none of the user config that hands the vendor tools or workspace roots. Codex:
     `--ignore-user-config` (drops the MCP servers such as nexus and courier, the hooks and the
     config's model; auth still works) plus its shell, exec and image tools disabled. Codex still
     sends its global `~/.codex/AGENTS.md` (the generated rules, which name the workspace roots)
     and its skill list; no flag drops them, one more reason its tools stay off. Gemini: an empty
     `GEMINI_CLI_HOME` whose only settings are API-key auth, no directory tree and no tools
     (`tools.core: []`), plus `--allowed-mcp-server-names none` and `GEMINI_CLI_NO_RELAUNCH`
     (otherwise Gemini runs in a relaunched child that a `kill` of the parent misses). A
     workspace-local `includeDirectories: []` does NOT clear the user's list on 0.55.1: lists
     concatenate. Local capture 2026-10-03, nothing sent to Google: the old setup's first request
     named all four private roots and offered `read_file`/`glob`/`grep_search` over them; the
     empty home's named none and offered no tools.
   - WATCH the event stream and stop the run at the first tool call: any Codex item other than a
     message, reasoning, todo list or error, any Gemini `tool_use`. A refutation of a pasted prompt needs no tools,
     and neither CLI is offered one, so a tool call means the isolation failed. The watcher sees
     a call only after it starts (the positive control's command had already run), which is why
     the tools are off rather than merely watched, and why a stop is an incident (below).
   ```bash
   codex_read()  { jq -eRn '[inputs | fromjson? | .item.type? // empty] | any(IN("agent_message", "reasoning", "todo_list", "error") | not)' "$1" > /dev/null; }
   gemini_read() { jq -eRn '[inputs | fromjson? | select(.type? == "tool_use")] | length > 0' "$1" > /dev/null; }
   stop_vendor() { pkill -KILL -P "$1" 2>/dev/null; kill -KILL "$1" 2>/dev/null; }
   vendor_watch() {  # $1 pid, $2 detector, $3 event log, $4 deadline (s). rc 90 = export-incident, 91 = timeout, else the CLI's
     local s=0 rc
     while kill -0 "$1" 2>/dev/null; do
       if "$2" "$3"; then stop_vendor "$1"; echo "EXPORT INCIDENT: tool call, see $3"; return 90; fi
       if [ "$s" -ge "${4:-300}" ]; then stop_vendor "$1"; echo "TIMEOUT"; return 91; fi
       sleep 1; s=$((s + 1))
     done
     wait "$1"; rc=$?
     if "$2" "$3"; then echo "EXPORT INCIDENT: tool call, see $3"; return 90; fi
     return "$rc"
   }

   # Codex: own empty dir, no user config, no tools; model read from the account's catalog (below).
   c=$(mktemp -d); mkdir "$c/cwd"
   m=$(codex debug models | jq -r '[.models[] | select(.visibility == "list")] | sort_by(.priority) | .[0].slug // empty')
   [ -n "$m" ] || echo "codex: catalog lists no model -> report model-unavailable"
   ( cd "$c/cwd" && exec codex exec --json --ephemeral --skip-git-repo-check --ignore-user-config \
       --sandbox read-only --disable shell_tool --disable unified_exec --disable view_image \
       -m "$m" -o "$c/reply.md" "<refute prompt>" ) < /dev/null > "$c/events.jsonl" 2> "$c/stderr" &
   vendor_watch $! codex_read "$c/events.jsonl"; echo "codex rc=$?"
   # reply: $c/reply.md. errors (404, auth): "error"/"turn.failed" events in $c/events.jsonl, then $c/stderr.
   # GATE: rc 90, or a reply citing files not in the prompt -> STOP here; do not start Gemini.

   # Gemini: Pro alias + an EMPTY home and workspace, else it confabulates or sees the roots (gotcha (c)).
   g=$(mktemp -d); mkdir -p "$g/home/.gemini" "$g/cwd"
   printf '{"security":{"auth":{"selectedType":"gemini-api-key"}},"context":{"includeDirectoryTree":false},"tools":{"core":[]}}' \
     > "$g/home/.gemini/settings.json"
   ( cd "$g/cwd" && export GEMINI_CLI_HOME="$g/home" GEMINI_CLI_NO_RELAUNCH=true && exec gemini --skip-trust \
       --approval-mode plan --model pro --allowed-mcp-server-names none --output-format stream-json \
       -p "<refute prompt>" ) < /dev/null > "$g/events.jsonl" 2> "$g/stderr" &
   vendor_watch $! gemini_read "$g/events.jsonl"; echo "gemini rc=$?"   # 41 = no GEMINI_API_KEY
   jq -Rrj 'fromjson? | select(.type == "message" and .role == "assistant") | .content' "$g/events.jsonl"   # the reply
   ```
   The CLIs reach their own model API; that egress is the point - but DEFAULT to sending a
   concise summary (the framed claim + the minimal diff/code under test), NEVER the raw
   workspace or whole files. Two harness gotchas:
   (a) the `codex exec` sandbox default is version-volatile - `workspace-write` on 0.139.0,
   `read-only` on 0.140.0 (disk-verified 2026-06-17) - so ALWAYS pass `--sandbox read-only`
   (or `-s read-only`) explicitly and never depend on the default. (b) In Claude Code a
   Task/Workflow SUBAGENT's sandbox classifier blocks the vendor-CLI call as private-source
   exfiltration, so the dispatch often has to run in the MAIN loop (Bash sandbox disabled for
   that call) or behind an explicit `codex`/`gemini` Bash allowlist; running it in the main
   loop trades away the worker context-hygiene benefit, so distill the raw output yourself
   before continuing.
   (c) gemini-cli CONFABULATES two ways on a normal dev box: the configured default model is often
   a tiny one (`gemini-3.1-flash-lite` here) that IGNORES the pasted code and invents file paths;
   and its workspace file-discovery BLEEDS unrelated files from `context.includeDirectories` (and
   cwd) into the review. FIX (both needed): pass the flagship (`--model pro`, the CLI's alias for
   its current Pro model: `gemini-2.5-pro` when verified below, `gemini-3.1-pro-preview` on 0.55.1)
   AND run from an isolated empty dir with no workspace roots (on 0.55.1 that takes the empty
   `GEMINI_CLI_HOME` in the snippet; it used to be a workspace-local
   `context.includeDirectories: []`). Verified 2026-06-23: without both, gemini hallucinated the
   SAME non-existent `~/.codex/.tmp/plugins/.../omniverse/EXECUTION.md` finding 4x (even isolated,
   because the user's global `includeDirectories` reached `~/.codex`); with both, it returned a
   clean, code-grounded verdict. A reply that cites files NOT in your pasted prompt is no longer
   dismissed as confabulation: from the reply alone a made-up path and a real read look the same,
   so it is an export incident (below).

   **Model selection: read it from the account, never hard-code or guess.** Slugs go stale and
   differ per account. Codex: the first `visibility: "list"` entry by `priority` in `codex debug
   models` (the logged-in account's catalog; `gpt-5.6-terra` on 2026-10-03), passed with `-m`.
   Not the `model =` in `~/.codex/config.toml` (its `gpt-5.6-sol` is refused on this ChatGPT
   account; `--ignore-user-config` skips it anyway), and the catalog is a shortlist, not proof
   (`gpt-5.5` was listed yet returned 404). Gemini: the `pro` alias, never the configured default
   (gotcha (c)). If the vendor refuses the model (404, unknown model, "not supported when using
   Codex with a ChatGPT account"), report `model-unavailable` with the slug and the CLI's error
   line, or `unauthenticated` if the error is about credentials, and stop for that vendor. Do NOT
   retry with other slugs: each retry re-sends the export, and the human picks the next model.

   **Gemini's key: report it, never hunt for it.** Gemini's settings select `gemini-api-key`
   auth, so it needs `GEMINI_API_KEY` in its environment; without it, it exits 41. Report
   `unauthenticated` with this fix for the human: "run `bash
   ~/.dotfiles/scripts/setup-gemini-cross-check.sh` (puts the key in Keychain service
   `ea-gemini-api-key`, exported to new shells by `~/.zshenv`; Windows:
   `~/.dotfiles/scripts/setup-gemini-cross-check.ps1`), then start a new session". Never search
   env files, keychains, shell history or other configs for a key, and never switch Gemini to
   another auth type.

   **Export mode (what data leaves the boundary):**
   - *Concise summary (DEFAULT):* the framed claim + the specific diff/snippet under test.
     Enough for almost every cross-check; this is the normal path.
   - *Raw file/workspace export (requires explicit human approval):* only when the vendor must
     see the full tree. Flag it as a HIGH-RISK export, state plainly what is leaving the
     boundary, get the operator's nod, THEN proceed. Never self-approve a raw export.

   **A reply that read or cites files not in the prompt is a raw export.** If a vendor's event
   stream shows a tool call (`vendor_watch` rc 90), or its reply names or quotes specific files, paths or
   repo history that were not in the pasted prompt, treat it as an unapproved raw export, not
   as noise: stop the dispatch (kill that CLI, do not start or continue the other one, do not
   retry), keep the reply out of the synthesis, and report an `export-incident` to the human:
   the vendor, the model, the dir it ran in, and every path or command it read or cited. Only
   the human decides whether it was a real read and what follows.

   **Report each vendor with a STRUCTURED status, never a vague "unavailable"** (the
   fresh-context Claude refutation still stands regardless; NEVER fabricate a vendor response):
   - **CLI-missing** - the `codex`/`gemini` binary is not installed or not on PATH.
   - **unauthenticated** - installed but no valid credentials (no API key / not logged in).
     Gemini's exit 41 lands here, with the key fix above; never search for a key.
   - **model-unavailable** - authenticated, but the vendor refused the model (404, unknown
     model, not supported on this account). Report the slug and the error line; never retry
     with guessed slugs.
   - **export-approval-needed** - a raw export was required but not approved; fall back to the
     concise summary and report that.
   - **policy-blocked** - the harness/CLI policy refused the export (e.g. the subagent sandbox
     classifier). Report it AS policy-blocked; do NOT engineer a workaround or retry - the
     block is a real constraint on the cross-check, not a puzzle to route around.
   - **timeout** - no return within the `gtimeout`/harness window.
   - **export-incident** - the vendor read, or cites, files not in the pasted prompt. The
     dispatch stopped; the human decides what follows.
   - **succeeded** - returned a verdict (note any degradation, e.g. only one model answered).
4. **The worker returns ONLY the distilled verdict:** the key agreements, the
   DISAGREEMENTS verbatim-enough to be actionable (do NOT over-compress away the dissent
   - it is the whole point), and each refuter's strongest counter-argument (the fresh-context
   Claude, Codex, and Gemini). Not the raw transcripts.
5. **You synthesize a PROPOSAL.** Combine the THREE independent refutations (fresh-Claude +
   Codex + Gemini) into: (a) the claim's strongest surviving objection, (b) whether it changes
   the decision, (c) a recommended action. Your own (author) view is the claim UNDER TEST, not
   a fourth refuting vote - do not let it overrule the panel. Adversarial/diversity synthesis,
   never a vote count. PROPOSE; never auto-apply.

## Common Rationalizations (reject these)

- "Three models agreed, so it's right." Agreement is not evidence - judges correlate
  ("Nine Judges, Two Effective Votes," arXiv:2605.29800). Weight the strongest argument,
  not the headcount.
- "Ask them what they think." Sycophancy makes that worthless. Ask them to REFUTE.
- "Run it on every change." No - it is for rare high-stakes diffs. Routine use is noise
  and cost.
- "Let the worker keep the full transcripts in context." That is the context-rot this
  delegation exists to prevent. The worker returns the distilled verdict only.

## Red Flags

- A majority-vote or averaged score in the output. That is the rejected technique.
- The dissent compressed to "they mostly agreed." Surface the actual disagreement.
- Any CLI invoked with write/network access. Read-only/sandboxed only.
- A CLI started inside a repo or any populated dir, given `-C` / `--add-dir` /
  `--include-directories` or the user's config and MCP servers, run unwatched, or a prompt that
  says where the code lives. Read-only sandboxes still read.
- A reply citing files not in the prompt synthesized as noise instead of stopped and reported
  as an `export-incident`.
- A 404/unsupported model "fixed" by trying other slugs, or a missing Gemini key searched for.
- A vendor reported as a vague "unavailable" instead of a structured status (CLI-missing /
  unauthenticated / model-unavailable / export-approval-needed / policy-blocked / timeout /
  export-incident). The status is the actionable signal.
- Raw files or the workspace exported to a vendor CLI without explicit human approval, or a
  policy-blocked export "worked around" in-agent. Concise summary is the default; a block is a
  constraint, not a puzzle.
- The proposal auto-applied. It proposes; the human (or you, after the human's nod)
  decides.

## Verification

- The output names each vendor's verdict + strongest counter-argument, and a synthesized
  recommendation that preserves any disagreement.
- Each vendor carries a STRUCTURED status (CLI-missing / unauthenticated / model-unavailable /
  export-approval-needed / policy-blocked / timeout / export-incident / succeeded), never a
  vague "unavailable".
- Each CLI ran from its own fresh empty temp dir with the user's config and MCP servers off and
  its event stream watched, and no tool call read a file (or the run stopped as an
  `export-incident`).
- The export was the concise summary by default; any raw-file/workspace export was explicitly
  approved by the human first, and a policy-blocked export is surfaced as such, not worked around.
- The raw transcripts did NOT enter the main context (only the distilled verdict did).
- No CLI ran with write/network/danger access.
- It PROPOSED; nothing was applied.

## Related

- The decision record this often feeds: `docs/decisions/` (ADR before an architecture bet).
- `coding-mastermind-help` - when to reach for this vs other levers.
- Rationale: kit `SPEC.md` (the enforcers-vs-advisors and multi-model verdicts).
