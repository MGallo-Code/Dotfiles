# Gemini Cross-Check Setup

This wires Gemini CLI for the `coding-mastermind-cross-check` workflow without
committing API keys.

This is intended to be a permanent setup, not a one-off shell export. The root
cause was that agent-spawned non-interactive shells could not see
`GEMINI_API_KEY`; the macOS setup makes new shells inherit the key from Keychain
and pins the model consistently.

## Model

Use:

```text
gemini-3.1-flash-lite
```

This model ID is present in the installed Gemini CLI bundle on this Mac
(`@google/gemini-cli` 0.47.0).

## macOS

Run from EA:

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

Run from EA in PowerShell:

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

For manual Gemini refutation:

```bash
gemini --skip-trust --approval-mode plan -m gemini-3.1-flash-lite -p "Try to REFUTE this: ..."
```

If a future agent says Gemini is unavailable, first check that a new shell sees
the key without printing it:

```bash
zsh -lc 'test -n "$GEMINI_API_KEY" && echo GEMINI_API_KEY=present || echo GEMINI_API_KEY=missing'
```

## Rules

- Do not paste the API key into chat.
- Do not write the API key into EA, `agent-skills`, `.env`, or git-tracked files.
- Rotate by rerunning the setup script and pasting the new key.
