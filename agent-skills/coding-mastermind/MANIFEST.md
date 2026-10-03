# coding-mastermind - MANIFEST

The kit's provenance record: the build date and the tool-version baseline the kit was
built against, so `coding-mastermind-update` has a baseline to diff future platform
versions against. This is the system-level analog of a `package-lock.json`.

- **Kit version:** v1.0
- **Implementation date:** 2026-06-16
- **Last re-stamped:** 2026-08-17 (WSL + Windows agent refresh: Codex pin DELIBERATELY
  BUMPED 0.144.1 -> 0.147.0 after `scripts/codex-pin-preflight.sh 0.147.0` passed
  5/5, including forward/backward config parsing; the installed WSL and Windows CLIs
  both report the exact pin. Claude Code 2.1.206 -> 2.1.233 and Gemini CLI 0.50.0 ->
  0.55.1. Reverified the load-bearing facts: WSL Codex 0.147.0 still defaults
  `codex exec` to `danger-full-access`, so cross-check must keep passing
  `-s read-only`; Gemini `plan` remains read-only; Claude Stop/SubagentStop,
  PreToolUse, and `.claude/skills` behavior remains supported. Toolchain this machine:
  WSL2, node v22.23.1, npm 10.9.8, git 2.34.1. The canonical pin remains dotfiles
  `manifest.sh CODEX_PIN` / `manifest.ps1 $CodexPin`, warn-on-drift in both syncs.)
- **Built/verified on:** macOS (darwin). Note: `timeout` is absent on macOS; use
  `gtimeout` (coreutils) or the harness timeout. `gtimeout` was NOT installed at
  build time.

## Agent-platform baseline (disk-verified; built 2026-06-16, re-verified 2026-06-17)

| Tool | Baseline version | Notes |
|------|------------------|-------|
| Claude Code | 2.1.233 | latest on 2026-08-17; npm global on WSL, native install on Windows; macOS remains npm-under-nvm by design |
| Codex CLI | 0.147.0 | npm global, PINNED - canonical pin lives in dotfiles `manifest.sh CODEX_PIN` (+ `manifest.ps1 $CodexPin`), both syncs warn on drift; bump ONLY via `~/.dotfiles/scripts/codex-pin-preflight.sh <version>` (pin bumped 2026-08-17 from 0.144.1 after preflight PASS). `codex exec` sandbox default is version-volatile and remains `danger-full-access` on WSL 0.147.0; always pass `-s read-only` |
| Gemini CLI | 0.55.1 | latest on 2026-08-17; npm global on WSL and Windows; `gemini --approval-mode plan` remains read-only (`plan (read-only mode)`), which blocks writes, not reads |
| node | 22.23.1 (WSL) | gate checks are plain ESM `.mjs`; original macOS build baseline was 22.17.1 |
| npm | 10.9.8 (WSL) | original macOS build baseline was 11.11.0 |
| git | 2.34.1 (WSL) | original Apple build baseline was 2.50.1 |

## Capability facts the kit depends on (re-check these on update)

- **PreToolUse exit-2** reliably blocks Bash in Claude Code 2.1.x; it does NOT reliably
  block Write/Edit or MCP. So the hard gate for Write-touching invariants is the CI
  check RE-RUN at the `Stop` gate, not a per-write PreToolUse hook.
- **Stop / SubagentStop** can attach `additionalContext` (since v2.1.151). Current
  docs cap hook output strings at 10,000 characters and Stop continuation loops at
  8 consecutive continuations. A Stop hook blocks turn completion via exit 2 or
  `{"decision":"block","reason":...}`.
- **`.claude/skills` auto-load** (since v2.1.157); `disallowed-tools` skill frontmatter
  (since v2.1.152); output-styles were REMOVED (v2.1.91) - do not depend on them.
- **The portable enforcement layer is CI** (vendor-neutral GitHub Actions) plus the
  constitution/rules file every agent reads. Hooks are Claude-Code-specific. The
  invariant LIVES in CI; each agent gets the best in-loop enforcement its own harness
  supports (Codex has `/review` + an OS sandbox; Gemini has its own).
- **Cross-vendor CLI dispatch (the cross-check skill), re-verified 2026-08-17:** the
  `codex exec` sandbox default is VERSION-VOLATILE - `workspace-write` on 0.139.0,
  `read-only` on 0.140.0, and `danger-full-access` on 0.142.4 macOS (2026-07-02) and
  on 0.142.4/0.144.1 WSL (2026-07-10) and 0.147.0 WSL (2026-08-17; all
  disk-verified via the `codex exec` session header). So ALWAYS pass
  `--sandbox read-only` (`-s read-only`) explicitly and never depend on the default.
  `gemini --approval-mode plan` remains read-only for cross-check verification calls
  (0.55.1 `--help` documents `plan (read-only mode)`). And a Claude Code Task/Workflow SUBAGENT's
  sandbox classifier blocks the vendor-CLI call as private-source exfiltration, so the
  dispatch must run in the main loop (sandbox disabled for that call) or behind an explicit
  `codex`/`gemini` Bash allowlist; the worker context-hygiene benefit is then traded off.
  Re-check both on update.
- **Vendor-CLI isolation (the cross-check step 3 snippet), verified 2026-10-03 on macOS with
  Codex 0.147.0 and Gemini 0.55.1:** read-only sandboxes block WRITES, NOT READS (a
  `codex exec -s read-only` started inside a repo read its files and sent excerpts to
  OpenAI), so every isolation flag below is load-bearing. Re-check each on update.
  - Codex: `--ignore-user-config` skips `config.toml` (MCP servers, hooks, default model)
    but still sends `~/.codex/AGENTS.md` and the skill list. `--disable shell_tool
    --disable unified_exec --disable view_image` leaves no command tool (a "run pwd"
    prompt yields no `command_execution`). `codex debug models` is the model source: the
    account's catalog with `visibility` and `priority` (top `list` entry `gpt-5.6-terra`;
    the config's `gpt-5.6-sol` absent; `gpt-5.5` listed yet 404). With `--json`, tool
    calls are `item.*` events whose `item.type` is not `agent_message`/`reasoning`.
  - Gemini: `GEMINI_CLI_HOME` replaces the home for settings
    (`$GEMINI_CLI_HOME/.gemini/settings.json`). `context.includeDirectories` has
    `mergeStrategy: concat`, so a workspace-local `[]` does NOT clear the user's list;
    `context.includeDirectoryTree` defaults to true. `tools.core: []` registers no tools.
    `--allowed-mcp-server-names <unknown name>` blocks every MCP server. Without
    `GEMINI_CLI_NO_RELAUNCH` the CLI relaunches as a child that a kill of the parent
    misses. `--model pro` resolves to `gemini-3.1-pro-preview`. `--output-format
    stream-json` reports tool calls as `tool_use` events. Stdin is merged into `-p`.
  - Re-check without sending anything to a vendor: Gemini honors `GOOGLE_GEMINI_BASE_URL`,
    so run the snippet with a dummy `GEMINI_API_KEY` against a localhost server that logs
    the request; the first request must name no home path and declare no tools. Never
    test against the real `~/.gemini` (it loads user hooks and MCP servers).

## Gate-tool baselines (recommended pins; install per-repo as needed)

These are the linters/scanners the kit's checks can use. None except node are required
for the SBIC instance (its checks are pure `.mjs` + pgTAP). Marked "not installed" were
not on PATH at build; treat their pins as fresh, unvalidated adoptions to verify before
relying on their output.

| Tool | Recommended pin | Installed at build? | Purpose |
|------|-----------------|---------------------|---------|
| ast-grep CLI + `ast-grep-mcp` | 0.43.0 (mcp 2026-06-13) | no | structural rule that is a CI gate AND agent-callable |
| jscpd | 5.0.9 (Rust engine; v4.2.5 = legacy TS) | no | clone/duplication detection (validate v5 output before trusting counts) |
| knip | 6.17.1 | no | dead-code / unused-export detection |
| dependency-cruiser | 17.4.3 (do NOT float to v18 beta) | no | import-graph rules |
| Squawk | 2.58.0 | no | migration linter |
| osv-scanner / socket | latest | no | hallucinated-package + advisory check (item 11b) |
| gitleaks | (already in SBIC CI) | n/a | secret scan |
| mutation testing | cargo-mutants (Rust) / Stryker (TS) / mutmut (Python) | no | diff-scoped surviving-mutant check |
| spec-kit | 0.10.2 | no | steal the constitution file + `/analyze` pass only |

## How to refresh this baseline

Run `coding-mastermind-update`: it reads this file, fetches current tool versions
(`npm view @anthropic-ai/claude-code version` and the Codex/Gemini equivalents +
their changelogs), diffs against the capability facts above, and proposes a
changes list + a re-stamped MANIFEST for approval. It PROPOSES, never auto-applies.

Codex pin bumps additionally go through `~/.dotfiles/scripts/codex-pin-preflight.sh
<version>` (sandboxed forward/backward config-compat proof against a CODEX_HOME clone)
BEFORE the pin moves in dotfiles `manifest.sh`/`manifest.ps1`; then every machine
installs the exact new pin at its next sync (lockstep).
