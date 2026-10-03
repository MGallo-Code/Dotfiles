# Gemini Cross-Check Setup

This wires Gemini CLI for the `coding-mastermind-cross-check` workflow without
committing API keys.

This is intended to be a permanent setup, not a one-off shell export. The root
cause was that agent-spawned non-interactive shells could not see
`GEMINI_API_KEY`; the macOS setup makes new shells inherit the key from Keychain
and pins the model consistently.

## Model

The setup pins `gemini-3.1-flash-lite` as Gemini's everyday default (in
`~/.gemini/settings.json`, `GEMINI_MODEL` and, despite its name,
`GEMINI_CROSS_CHECK_MODEL`). Cross-checks never use it: it is the tiny model that
ignores pasted code and invents file paths. The `coding-mastermind-cross-check`
skill passes `--model pro` and runs Gemini with an empty `GEMINI_CLI_HOME`, so none
of these settings reach a cross-check.

## macOS

Run from `~/.dotfiles`:

```bash
bash scripts/setup-gemini-cross-check.sh
```

What it does:

- Prompts for `GEMINI_API_KEY` with hidden input.
- Stores the key in macOS Keychain under service `ea-gemini-api-key`.
- Adds a managed block to `~/.zshenv` so new non-interactive agent shells inherit
  `GEMINI_API_KEY`, `GEMINI_MODEL`, and `GEMINI_CROSS_CHECK_MODEL`.
- Creates `~/.local/bin/gemini-flash-lite` as a Keychain-backed wrapper.
- Updates `~/.gemini/settings.json` to use API-key auth and
  `gemini-3.1-flash-lite`.
- Runs a one-line Gemini verification prompt.

## Idempotency

The macOS setup is safe to rerun:

- Keychain storage uses an upsert for service `ea-gemini-api-key`.
- The `~/.zshenv` block is marked and replaced on each run, so duplicate blocks
  do not accumulate.
- `~/.local/bin/gemini-flash-lite` is overwritten deterministically.
- `~/.gemini/settings.json` is merged into the desired auth/model state.
- `--verify-only` performs no writes.

The permanent path is `~/.zshenv` plus Keychain. The wrapper is only a
convenience.

Verify later with:

```bash
bash scripts/setup-gemini-cross-check.sh --verify-only
```

## Windows

Run from `~/.dotfiles` in PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/setup-gemini-cross-check.ps1
```

What it does:

- Prompts for `GEMINI_API_KEY` with hidden input.
- Stores the key in a DPAPI-protected per-user file at
  `%USERPROFILE%\.config\ea\gemini-api-key.dpapi`.
- Sets user environment variables only for non-secret model names:
  `GEMINI_MODEL` and `GEMINI_CROSS_CHECK_MODEL`.
- Creates a shim at `%USERPROFILE%\.local\bin\gemini.cmd` and a wrapper at
  `%USERPROFILE%\.local\bin\gemini-flash-lite.ps1`.
- Prepends `%USERPROFILE%\.local\bin` to the user PATH so `gemini ...` works in
  new agent shells without storing the API key as a plain environment variable.
- Updates `%USERPROFILE%\.gemini\settings.json` to use API-key auth and
  `gemini-3.1-flash-lite`.

Restart terminals and agent sessions afterward.

Verify later with:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/setup-gemini-cross-check.ps1 -VerifyOnly
```

## Dotfiles

The scripts should be carried by dotfiles, but the key itself must remain
machine-local:

- macOS key storage: Keychain service `ea-gemini-api-key`.
- Windows key storage: DPAPI-protected file under `%USERPROFILE%\.config\ea`.
- Dotfiles may install/update the setup scripts, wrapper logic, model defaults,
  and PATH/profile hooks.
- Dotfiles must never contain `GEMINI_API_KEY` or a decrypted key.

## Cross-Check Command

Run Gemini for a cross-check only through the snippet in the
`coding-mastermind-cross-check` skill (step 3), never as a bare `gemini` call. Plan mode
blocks writes, not reads: started from a repo, or with your user settings (which list
your workspace roots and MCP servers), Gemini can read and send private files. On 0.55.1
a workspace-local `includeDirectories: []` does not clear that list (lists concatenate);
the snippet's empty `GEMINI_CLI_HOME` does. The skill also holds the export policy and
the structured statuses to report.

If Gemini exits 41 (`unauthenticated`), check that a new shell sees the key without
printing it, and never search for a key:

```bash
zsh -lc 'test -n "$GEMINI_API_KEY" && echo GEMINI_API_KEY=present || echo GEMINI_API_KEY=missing'
```

## Rules

- Do not paste the API key into chat.
- Do not write the API key into EA, `agent-skills`, `.env`, or git-tracked files.
- Rotate by rerunning the setup script and pasting the new key.
