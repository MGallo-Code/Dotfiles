#!/usr/bin/env bash
set -euo pipefail

MODEL="gemini-3.1-flash-lite"
SERVICE="ea-gemini-api-key"
ACCOUNT="${USER:-michael}"
VERIFY_ONLY=0
WRITE_ZSHENV=1
WRITE_WRAPPER=1

usage() {
  cat <<'USAGE'
Usage: scripts/setup-gemini-cross-check.sh [options]

Stores a Gemini API key in macOS Keychain and wires non-interactive shells so
agent cross-checks can run Gemini Flash Lite without committing secrets.

Idempotent by design:
  - Keychain item is upserted, not duplicated.
  - The ~/.zshenv managed block is replaced, not appended repeatedly.
  - The wrapper is overwritten deterministically.
  - ~/.gemini/settings.json is merged to the desired auth/model state.

Options:
  --model MODEL       Gemini model to export. Default: gemini-3.1-flash-lite
  --verify-only       Do not prompt or write files; just verify Gemini works
  --no-zshenv         Do not update ~/.zshenv
  --no-wrapper        Do not create ~/.local/bin/gemini-flash-lite
  -h, --help          Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)
      MODEL="${2:?--model requires a value}"
      shift 2
      ;;
    --verify-only)
      VERIFY_ONLY=1
      shift
      ;;
    --no-zshenv)
      WRITE_ZSHENV=0
      shift
      ;;
    --no-wrapper)
      WRITE_WRAPPER=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_command gemini
require_command security

existing_key() {
  security find-generic-password -a "$ACCOUNT" -s "$SERVICE" -w 2>/dev/null || true
}

store_key() {
  local current=""
  current="$(existing_key)"

  if [[ -n "$current" ]]; then
    echo "A Gemini key is already stored in Keychain service '$SERVICE'."
    printf "Press Enter to keep it, or paste a replacement key (input hidden): "
  else
    printf "Paste GEMINI_API_KEY for Gemini CLI (input hidden): "
  fi

  local key=""
  IFS= read -r -s key
  printf "\n"

  if [[ -z "$key" ]]; then
    if [[ -z "$current" ]]; then
      echo "No key provided and no existing Keychain key found." >&2
      exit 1
    fi
    echo "Keeping existing Keychain key."
    return
  fi

  security add-generic-password -U -a "$ACCOUNT" -s "$SERVICE" -w "$key" >/dev/null
  unset key
  echo "Stored Gemini API key in macOS Keychain service '$SERVICE'."
}

update_zshenv() {
  local zshenv="${ZDOTDIR:-$HOME}/.zshenv"
  local begin="# >>> EA Gemini cross-check env >>>"
  local end="# <<< EA Gemini cross-check env <<<"
  local tmp
  tmp="$(mktemp)"

  if [[ -f "$zshenv" ]]; then
    awk -v begin="$begin" -v end="$end" '
      $0 == begin { skip = 1; next }
      $0 == end { skip = 0; next }
      skip != 1 { print }
    ' "$zshenv" > "$tmp"
  fi

  cat >> "$tmp" <<EOF
$begin
if command -v security >/dev/null 2>&1; then
  if [ -z "\${GEMINI_API_KEY:-}" ]; then
    __ea_gemini_value="\$(security find-generic-password -a "$ACCOUNT" -s "$SERVICE" -w 2>/dev/null || true)"
    if [ -n "\$__ea_gemini_value" ]; then
      export GEMINI_API_KEY
      GEMINI_API_KEY=\$__ea_gemini_value
    fi
    unset __ea_gemini_value
  fi
fi
export GEMINI_MODEL="\${GEMINI_MODEL:-$MODEL}"
export GEMINI_CROSS_CHECK_MODEL="\${GEMINI_CROSS_CHECK_MODEL:-$MODEL}"
$end
EOF

  mv "$tmp" "$zshenv"
  chmod 600 "$zshenv"
  echo "Updated $zshenv with a managed Gemini env block."
}

write_wrapper() {
  local dir="$HOME/.local/bin"
  local wrapper="$dir/gemini-flash-lite"
  mkdir -p "$dir"

  cat > "$wrapper" <<EOF
#!/usr/bin/env bash
set -euo pipefail

service="\${GEMINI_KEYCHAIN_SERVICE:-$SERVICE}"
account="\${GEMINI_KEYCHAIN_ACCOUNT:-\${USER:-michael}}"
model="\${GEMINI_MODEL:-\${GEMINI_CROSS_CHECK_MODEL:-$MODEL}}"

if [[ -z "\${GEMINI_API_KEY:-}" ]]; then
  if command -v security >/dev/null 2>&1; then
    key="\$(security find-generic-password -a "\$account" -s "\$service" -w 2>/dev/null || true)"
    if [[ -n "\$key" ]]; then
      export GEMINI_API_KEY="\$key"
    fi
    unset key
  fi
fi

if [[ -z "\${GEMINI_API_KEY:-}" ]]; then
  echo "GEMINI_API_KEY is not available. Run the setup-gemini-cross-check.sh installer." >&2
  exit 41
fi

export GEMINI_MODEL="\$model"
exec gemini "\$@"
EOF

  chmod 700 "$wrapper"
  echo "Created wrapper: $wrapper"
  echo "Add ~/.local/bin to PATH if it is not already there."
}

update_gemini_settings() {
  local settings="$HOME/.gemini/settings.json"
  mkdir -p "$HOME/.gemini"

  if ! command -v node >/dev/null 2>&1; then
    echo "Node not found; skipped ~/.gemini/settings.json update."
    return
  fi

  node -e '
    const fs = require("fs");
    const settingsPath = process.argv[1];
    const model = process.argv[2];
    let settings = {};
    try {
      settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
    } catch (_) {
      settings = {};
    }
    settings.security ??= {};
    settings.security.auth ??= {};
    settings.security.auth.selectedType = "gemini-api-key";
    settings.model ??= {};
    settings.model.name = model;
    fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n", { mode: 0o600 });
  ' "$settings" "$MODEL"

  chmod 600 "$settings"
  echo "Updated $settings for gemini-api-key auth and model $MODEL."
}

verify() {
  local key
  key="$(existing_key)"
  if [[ -z "$key" && -n "${GEMINI_API_KEY:-}" ]]; then
    key="$GEMINI_API_KEY"
  fi
  if [[ -z "$key" ]]; then
    echo "No Gemini key found in Keychain or GEMINI_API_KEY." >&2
    exit 1
  fi

  echo "Verifying Gemini CLI with model $MODEL..."
  GEMINI_API_KEY="$key" GEMINI_MODEL="$MODEL" \
    gemini --skip-trust --approval-mode plan -m "$MODEL" \
      -p "Reply with exactly GEMINI_FLASH_LITE_OK."
}

if [[ "$VERIFY_ONLY" -eq 0 ]]; then
  store_key
  [[ "$WRITE_ZSHENV" -eq 1 ]] && update_zshenv
  [[ "$WRITE_WRAPPER" -eq 1 ]] && write_wrapper
  update_gemini_settings
fi

verify
