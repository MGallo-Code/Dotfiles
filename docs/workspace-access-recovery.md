# Michael Workspace Access Recovery

## What changed

The named `ea`, `wiki`, `sbic`, and `sysupdate` launchers are trusted boundaries. They now:

- preflight a bounded directory enumeration plus reversible create, read, and remove probe;
- launch from a child shell scope so the interactive parent keeps its original cwd;
- request Claude `bypassPermissions` and Codex `danger-full-access` with approvals disabled;
- re-probe after exit, save a diagnostic report, and move the parent to `$HOME` on an access failure;
- refuse missing, unnamed, or redirected roots and permission-policy overrides instead of launching
  somewhere else.
- reject Codex cwd, additional-write-root, profile, config, and remote overrides; use raw `codex`
  when intentionally changing those boundaries.

Claude's user setting is also converged to `permissions.defaultMode: "bypassPermissions"` with
`permissions.skipDangerousModePermissionPrompt: true`. Anthropic documents that user settings apply
across projects, that `defaultMode` includes `bypassPermissions` and is labeled in the desktop app,
and that a CLI `--permission-mode` overrides it for one session. See [Claude Code settings and
precedence](https://code.claude.com/docs/en/settings#permission-settings).

Codex uses the stable `approval_policy = "never"` and `sandbox_mode = "danger-full-access"` user
defaults. The trusted CLI launcher repeats both documented options explicitly. The previous beta
`default_permissions` default is removed because OpenAI documents that it must not be combined with
`sandbox_mode`.
OpenAI documents config precedence and the full-access built-in in the [Codex configuration
reference](https://learn.chatgpt.com/docs/config-file/config-reference) and the CLI overrides in the
[Codex command reference](https://learn.chatgpt.com/docs/developer-commands?surface=cli).

Claude Desktop shares `settings.json` with the CLI, but its permission mode is also a visible,
per-session control. Enable Settings, Claude Code, Allow bypass permissions mode, then select
Bypass permissions beside the send button for each affected or fresh local session. Anthropic
documents both the shared configuration and the Desktop mode selector in the
[Claude Desktop guide](https://code.claude.com/docs/en/desktop#choose-a-permission-mode). Managed
organization settings can disable this option.

Codex Desktop is a separate host surface. No official source located for this repair establishes
that its composer permission control is overridden by `config.toml`. A Desktop task that still shows
a read-only inherited envelope is therefore not repaired by editing task history or opaque global
state. Start a fresh task after configuration sync and treat a still-hidden Full Access control as
an `agent_sandbox_envelope` owned by that host. Do not patch the signed app or rewrite transcripts.

## Automatic report

Reports live under `~/.local/state/michael-workspace-access/`. On macOS/Linux the directory is mode
0700 and reports are mode 0600; Windows inherits the user-profile ACL. `latest.json` is atomically
replaced, and only the newest 25 reports are retained.
They contain categories, errno names, probe stages, mount state, known TCC bundle grant values, and a
coarse responsible-process chain. They do not contain raw paths, raw log lines, environment values,
commands, prompts, responses, history content, or transcripts.
The parent removes the uniquely named temporary probe if a bounded child times out. The prompt hook
runs only when the shell is at one of the four named roots, never inside project descendants such as
KeepTheCall. Automatic history checks use non-mutating access only for a direct, non-symlinked file
under `$HOME`; custom `$HISTFILE` project paths are recorded as skipped and never entered.

Run `wsdoctor` to summarize the newest report. If the denial happened only inside an agent while the
ordinary shell remained healthy, run `wsdoctor agent-read-only`. For a shell or prompt message with
otherwise working files, run `wsdoctor shell-message`.

## Failure taxonomy

| Category | Decisive evidence | Meaning |
|---|---|---|
| `agent_sandbox_envelope` | Agent reports denial while target and HOME probes pass | Evidence is consistent with a child or embedding-host restriction; the parent cannot prove that envelope. |
| `macos_tcc_system_policy` | `EPERM` under Documents on a writable mount, plus responsible-process TCC context | macOS privacy policy denied the app or responsible process. |
| `inaccessible_cwd_or_file_provider` | `ENOENT`, `ESTALE`, `EIO`, or timeout for the workspace while HOME passes | The cwd disappeared, became stale, or its provider stopped answering. |
| `read_only_mount` | `ST_RDONLY` or `EROFS` | The mounted filesystem is truly read-only. |
| `zsh_history_or_prompt_hook` | Workspace passes while the history directory or non-mutating history-file access probe fails, or a shell-only message is reported | The error is shell/session-history related rather than workspace access. |
| `unix_permissions_or_acl` | `EACCES` | POSIX mode bits or ACLs blocked access. |
| `unknown` | Failure without more specific evidence | Preserve the report and investigate without guessing. |

Classifiers may record more than one cause. `read_only_mount` and direct filesystem errno evidence
outrank weaker inference. An agent-reported denial with healthy parent probes has medium confidence:
a healthy parent probe cannot prove a
Desktop task's effective sandbox, and a visible TCC grant cannot prove which process macOS treated as
responsible for a denial.

Apple documents that Documents, Desktop, Downloads, network volumes, and similar locations are
protected by macOS privacy controls, and that Full Disk Access is assigned to specific apps. See
[Controlling app access to files](https://support.apple.com/en-euro/guide/security/secddd1d86a6/web)
and [Allow apps full disk access](https://support.apple.com/en-ie/guide/mac-help/mchlccb25729/mac).

## Short recovery path

1. Run `wsdoctor`. The launcher already moves the shell to `$HOME` when it can. If needed, run
   `cd "$HOME"` yourself.
2. For `agent_sandbox_envelope`, close only the affected task. Relaunch CLI work through `ea`,
   `wiki`, `sbic`, or `sysupdate`. In Claude Desktop, enable Allow bypass permissions mode in
   Settings, Claude Code, then choose Bypass permissions from the session's mode selector. In Codex
   Desktop, create a fresh task and verify its visible access control. If Full Access is still
   hidden, preserve the report and escalate it as a host-envelope issue. Do not edit task history.
3. For `macos_tcc_system_policy`, open System Settings, Privacy & Security, then Full Disk Access.
   Re-enable the responsible app shown by context: Terminal/Ghostty for the ordinary shell, Claude
   for Claude Desktop, or ChatGPT/Codex for Codex Desktop. Quit and reopen only that affected app,
   then run the same launcher probe again. Do not reset every TCC grant by default.
4. For `inaccessible_cwd_or_file_provider`, stay in `$HOME`, verify `ls "$HOME/Documents"`, then
   make the affected folder locally available from Finder if a provider owns it. Re-enter only after
   `python3 ~/.dotfiles/scripts/workspace-access-diagnostics.py probe --path <workspace>` succeeds.
5. For `read_only_mount`, inspect `mount` and `diskutil info` for the affected volume. Use Disk
   Utility First Aid if the filesystem needs repair; Apple documents that First Aid checks and
   repairs formatting and directory-structure errors in [Repair a storage device](https://support.apple.com/en-euro/guide/disk-utility/dskutl1040/mac).
6. For `zsh_history_or_prompt_hook`, compare with `zsh -f` from `$HOME`. If the clean shell works,
   inspect the configured `precmd` hooks, `$HISTFILE`, and its parent. Do not delete shell history as a
   first step.

Rebooting or repeatedly restarting every app is not the default recovery. Recover cwd, act on the
classified owner, restart only that process when TCC requires it, and re-run the bounded probe.
