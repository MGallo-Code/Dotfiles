# Core dev shell commands

# Sync all dotfiles-managed repos
sync() { bash ~/.dotfiles/sync.sh; }

# Navigate to project directory, optionally create new
proj() {
    local PROJECT_DIR=~/Documents/Projects

    if [[ "$1" == "-n" || "$1" == "--new" ]]; then
        local NEW_NAME="$2"

        if [ -z "$NEW_NAME" ]; then
            echo "Error: Please provide a name for the new project."
            echo "Usage: proj -n <project_name>"
            return 1
        fi

        local TARGET_DIR="$PROJECT_DIR/$NEW_NAME"

        if [ -d "$TARGET_DIR" ]; then
            echo "Error: Directory '$NEW_NAME' already exists."
            return 1
        fi

        echo "Creating project '$NEW_NAME'..."
        mkdir -p "$TARGET_DIR"
        cd "$TARGET_DIR" || return
    else
        if [ -z "$1" ]; then
            cd "$PROJECT_DIR" || return
        else
            local TARGET_DIR="$PROJECT_DIR/$1"
            if [ -d "$TARGET_DIR" ]; then
                cd "$TARGET_DIR" || return
            else
                echo "Error: Project '$1' not found. Use flag '-n' to create a new project"
                echo "Usage: proj -n <project_name>"
                return 1
            fi
        fi
    fi
}

# Launch Claude Code with local models on remote PC via Tailscale
_ollama_claude() {
    ANTHROPIC_AUTH_TOKEN=ollama \
    ANTHROPIC_API_KEY="" \
    ANTHROPIC_BASE_URL=http://100.124.149.107:11434 \
    claude --model "$1" "${@:2}"
}

# Default local model - best benchmarks, working tool calling
qwen() { _ollama_claude "qwen3.5:27b" "$@"; }

# Pure code generation - 92.7% HumanEval
qwen-coder() { _ollama_claude "qwen2.5-coder:32b" "$@"; }

# Default local model - 117 tok/s, fast for daily use
gemma() { _ollama_claude "gemma4:26b" "$@"; }

# Higher quality, slower (13 tok/s, 32K max context)
gemma31b() { _ollama_claude "gemma4:31b" "$@"; }

# Tab completion for proj
_proj_completion() {
    compadd $(find ~/Documents/Projects -maxdepth 1 -mindepth 1 -type d -not -path '*/.*' -exec basename {} \;)
}
compdef _proj_completion proj
