#!/usr/bin/env bash
# mlx-chat: Interactive MLX model launcher for Apple Silicon
# Installs dependencies, lists installed/available models, and runs chat

set -euo pipefail

# ── Data directory (required) ────────────────────────────────────────────────
if [[ $# -lt 1 ]] || [[ -z "$1" ]]; then
  echo "Usage: mlx-chat <data-dir>" >&2
  echo "  <data-dir>  Directory for venv and model weights" >&2
  exit 1
fi

DATA_DIR="$1"
mkdir -p "$DATA_DIR"
DATA_DIR="$(cd "$DATA_DIR" && pwd)"  # resolve to absolute path

VENV_DIR="$DATA_DIR/venv"
HF_CACHE_DIR="$DATA_DIR/models"
export HF_HUB_CACHE="$HF_CACHE_DIR"

# Colors
BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
RED='\033[31m'
RESET='\033[0m'

# Popular MLX models available for download (curated list)
RECOMMENDED_MODELS=(
  "mlx-community/Llama-3.3-70B-Instruct-4bit"
  "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit"
  "mlx-community/Meta-Llama-3.1-8B-Instruct-8bit"
  "mlx-community/Mistral-7B-Instruct-v0.3-4bit"
  "mlx-community/Mistral-Small-24B-Instruct-2501-4bit"
  "mlx-community/Qwen3-0.6B-4bit"
  "mlx-community/Qwen3-14B-4bit"
  "mlx-community/Qwen3-30B-A3B-4bit"
  "mlx-community/Qwen3-235B-A22B-4bit"
  "mlx-community/Qwen3-Coder-Next-4bit"
  "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"
  "mlx-community/Qwen2.5-7B-Instruct-4bit"
  "mlx-community/Qwen2.5-14B-Instruct-4bit"
  "mlx-community/Qwen2.5-32B-Instruct-4bit"
  "mlx-community/Qwen2.5-32B-Instruct-8bit"
  "mlx-community/Qwen2.5-72B-Instruct-4bit"
  "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit"
  "mlx-community/Qwen2.5-Coder-14B-Instruct-4bit"
  "mlx-community/Qwen2.5-Coder-32B-Instruct-4bit"
  "mlx-community/gemma-2-27b-it-4bit"
  "mlx-community/phi-4-4bit"
  "mlx-community/DeepSeek-R1-Distill-Qwen-32B-4bit"
  "mlx-community/DeepSeek-R1-Distill-Llama-70B-4bit"
)

# Other MLX models — niche use cases, extreme sizes, or older generations
OTHER_MODELS=(
  "mlx-community/Qwen3.5-4B-MLX-4bit"
  "mlx-community/Qwen3.5-9B-MLX-4bit"
  "mlx-community/Qwen3.5-27B-4bit"
  "mlx-community/Qwen3.5-35B-A3B-4bit"
  "mlx-community/Qwen3.5-122B-A10B-4bit"
  "mlx-community/Qwen3.5-397B-A17B-4bit"
  "mlx-community/Qwen3-4B-Thinking-2507-4bit"
  "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit"
  "mlx-community/Qwen3-235B-A22B-8bit"
  "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
  "mlx-community/Qwen2.5-3B-Instruct-4bit"
  "mlx-community/Qwen2.5-VL-3B-Instruct-4bit"
  "mlx-community/Qwen2.5-VL-7B-Instruct-4bit"
  "mlx-community/Qwen2.5-VL-7B-Instruct-8bit"
  "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit"
  "mlx-community/Qwen3-VL-2B-Instruct-4bit"
  "mlx-community/Qwen3-VL-4B-Instruct-4bit"
  "mlx-community/Qwen3-VL-8B-Instruct-4bit"
  "mlx-community/DeepSeek-R1-Distill-Qwen-1.5B-4bit"
  "mlx-community/DeepSeek-R1-Distill-Qwen-7B-4bit"
  "mlx-community/DeepSeek-R1-Distill-Qwen-14B-4bit"
  "mlx-community/DeepSeek-R1-0528-Qwen3-8B-4bit"
  "mlx-community/Qwen1.5-0.5B-Chat-4bit"
)

# ── Model metadata: "size|task" ──────────────────────────────────────────────
# Looked up via get_model_info(). Used to display size and purpose in the menu.
get_model_info() {
  case "$1" in
    # Llama
    mlx-community/Llama-3.3-70B-Instruct-4bit)                echo "~40GB|chat" ;;
    mlx-community/Meta-Llama-3.1-8B-Instruct-4bit)            echo "~5GB|chat" ;;
    mlx-community/Meta-Llama-3.1-8B-Instruct-8bit)            echo "~9GB|chat" ;;
    # Mistral
    mlx-community/Mistral-7B-Instruct-v0.3-4bit)              echo "~4GB|chat" ;;
    mlx-community/Mistral-Small-24B-Instruct-2501-4bit)       echo "~14GB|chat" ;;
    # Qwen 3
    mlx-community/Qwen3-0.6B-4bit)                            echo "~1GB|chat" ;;
    mlx-community/Qwen3-14B-4bit)                             echo "~9GB|chat" ;;
    mlx-community/Qwen3-30B-A3B-4bit)                         echo "~17GB|chat (MoE)" ;;
    mlx-community/Qwen3-235B-A22B-4bit)                       echo "~130GB|chat (MoE)" ;;
    mlx-community/Qwen3-Coder-Next-4bit)                      echo "~45GB|code" ;;
    mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit)          echo "~17GB|code (MoE)" ;;
    # Qwen 2.5
    mlx-community/Qwen2.5-7B-Instruct-4bit)                   echo "~5GB|chat" ;;
    mlx-community/Qwen2.5-14B-Instruct-4bit)                  echo "~9GB|chat" ;;
    mlx-community/Qwen2.5-32B-Instruct-4bit)                  echo "~18GB|chat" ;;
    mlx-community/Qwen2.5-32B-Instruct-8bit)                  echo "~34GB|chat" ;;
    mlx-community/Qwen2.5-72B-Instruct-4bit)                  echo "~40GB|chat" ;;
    mlx-community/Qwen2.5-Coder-7B-Instruct-4bit)             echo "~5GB|code" ;;
    mlx-community/Qwen2.5-Coder-14B-Instruct-4bit)            echo "~9GB|code" ;;
    mlx-community/Qwen2.5-Coder-32B-Instruct-4bit)            echo "~18GB|code" ;;
    # Gemma / Phi
    mlx-community/gemma-2-27b-it-4bit)                         echo "~16GB|chat" ;;
    mlx-community/phi-4-4bit)                                  echo "~8GB|chat + reasoning" ;;
    # DeepSeek R1
    mlx-community/DeepSeek-R1-Distill-Qwen-32B-4bit)          echo "~18GB|reasoning" ;;
    mlx-community/DeepSeek-R1-Distill-Llama-70B-4bit)          echo "~40GB|reasoning" ;;
    # Qwen 3.5 (vision)
    mlx-community/Qwen3.5-4B-MLX-4bit)                        echo "~3GB|vision + chat" ;;
    mlx-community/Qwen3.5-9B-MLX-4bit)                        echo "~6GB|vision + chat" ;;
    mlx-community/Qwen3.5-27B-4bit)                           echo "~16GB|vision + chat" ;;
    mlx-community/Qwen3.5-35B-A3B-4bit)                       echo "~20GB|vision + chat (MoE)" ;;
    mlx-community/Qwen3.5-122B-A10B-4bit)                     echo "~70GB|vision + chat (MoE)" ;;
    mlx-community/Qwen3.5-397B-A17B-4bit)                     echo "~220GB|vision + chat (MoE)" ;;
    # Qwen 3 (specialized)
    mlx-community/Qwen3-4B-Thinking-2507-4bit)                echo "~3GB|reasoning" ;;
    mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit)           echo "~17GB|chat (MoE)" ;;
    mlx-community/Qwen3-235B-A22B-8bit)                       echo "~250GB|chat (MoE)" ;;
    # Qwen 2.5 (small / vision)
    mlx-community/Qwen2.5-1.5B-Instruct-4bit)                 echo "~1GB|chat" ;;
    mlx-community/Qwen2.5-3B-Instruct-4bit)                   echo "~2GB|chat" ;;
    mlx-community/Qwen2.5-VL-3B-Instruct-4bit)                echo "~2GB|vision + chat" ;;
    mlx-community/Qwen2.5-VL-7B-Instruct-4bit)                echo "~5GB|vision + chat" ;;
    mlx-community/Qwen2.5-VL-7B-Instruct-8bit)                echo "~9GB|vision + chat" ;;
    mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit)           echo "~1GB|code" ;;
    # Qwen 3 VL
    mlx-community/Qwen3-VL-2B-Instruct-4bit)                  echo "~2GB|vision + chat" ;;
    mlx-community/Qwen3-VL-4B-Instruct-4bit)                  echo "~3GB|vision + chat" ;;
    mlx-community/Qwen3-VL-8B-Instruct-4bit)                  echo "~5GB|vision + chat" ;;
    # DeepSeek R1 (extra)
    mlx-community/DeepSeek-R1-Distill-Qwen-1.5B-4bit)         echo "~1GB|reasoning" ;;
    mlx-community/DeepSeek-R1-Distill-Qwen-7B-4bit)           echo "~5GB|reasoning" ;;
    mlx-community/DeepSeek-R1-Distill-Qwen-14B-4bit)          echo "~9GB|reasoning" ;;
    mlx-community/DeepSeek-R1-0528-Qwen3-8B-4bit)             echo "~5GB|reasoning" ;;
    # Legacy
    mlx-community/Qwen1.5-0.5B-Chat-4bit)                     echo "<1GB|chat (legacy)" ;;
    *) echo "" ;;
  esac
}

# Format a model line for display: "  NUM)  Model-Name       ~18GB  code"
format_model_line() {
  local idx="$1" model="$2" color="$3" status="$4"
  local short="${model#mlx-community/}"
  local info
  info=$(get_model_info "$model")
  if [[ -n "$info" ]]; then
    local size="${info%%|*}"
    local task="${info#*|}"
    printf "  ${color}%3d${RESET})  %-38s ${CYAN}%6s${RESET}  %-20s ${DIM}%s${RESET}\n" \
      "$idx" "$short" "$size" "$task" "$status"
  else
    printf "  ${color}%3d${RESET})  %-38s ${DIM}%28s${RESET}\n" \
      "$idx" "$short" "$status"
  fi
}

header() {
  echo ""
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${CYAN}║        MLX Chat — Apple Silicon      ║${RESET}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════╝${RESET}"
  echo ""
}

info()  { echo -e "${CYAN}▸${RESET} $*"; }
ok()    { echo -e "${GREEN}✓${RESET} $*"; }
warn()  { echo -e "${YELLOW}⚠${RESET} $*"; }
err()   { echo -e "${RED}✗${RESET} $*"; }

# ── Step 1: Ensure venv and dependencies ─────────────────────────────────────

ensure_deps() {
  if [[ ! -d "$VENV_DIR" ]]; then
    info "Creating virtual environment at ${DIM}$VENV_DIR${RESET}"
    python3 -m venv "$VENV_DIR"
  fi

  source "$VENV_DIR/bin/activate"

  if ! python -c "import mlx_lm" 2>/dev/null; then
    info "Installing mlx-lm (this may take a minute)..."
    pip install --upgrade pip -q
    pip install mlx-lm -q
    ok "mlx-lm installed"
  else
    ok "mlx-lm already installed"
  fi
}

# ── Step 2: Discover installed models ────────────────────────────────────────

get_installed_models() {
  local models=()
  if [[ -d "$HF_CACHE_DIR" ]]; then
    while IFS= read -r dir; do
      # Convert "models--mlx-community--Model-Name" → "mlx-community/Model-Name"
      local name="${dir#models--}"
      name="${name//--//}"
      # Only include mlx-community models (LLMs, not whisper)
      if [[ "$name" == mlx-community/* ]] && [[ "$name" != *whisper* ]]; then
        models+=("$name")
      fi
    done < <(ls "$HF_CACHE_DIR" 2>/dev/null | grep "^models--mlx-community" || true)
  fi
  printf '%s\n' ${models[@]+"${models[@]}"}
}

# ── Step 3: Build menu ──────────────────────────────────────────────────────

show_menu() {
  local -a installed=()
  local -a available=()

  # Read installed models
  while IFS= read -r m; do
    [[ -n "$m" ]] && installed+=("$m")
  done < <(get_installed_models)

  # Build available list (recommended models NOT already installed)
  for rec in "${RECOMMENDED_MODELS[@]}"; do
    local found=0
    for inst in ${installed[@]+"${installed[@]}"}; do
      if [[ "$rec" == "$inst" ]]; then
        found=1
        break
      fi
    done
    if [[ $found -eq 0 ]]; then
      available+=("$rec")
    fi
  done

  # Build other list (niche models NOT already installed)
  local -a other=()
  for rec in "${OTHER_MODELS[@]}"; do
    local found=0
    for inst in ${installed[@]+"${installed[@]}"}; do
      if [[ "$rec" == "$inst" ]]; then
        found=1
        break
      fi
    done
    if [[ $found -eq 0 ]]; then
      other+=("$rec")
    fi
  done

  local idx=1

  # Column headers
  local hdr
  hdr=$(printf "  ${DIM}      %-38s %6s  %-20s${RESET}" "Model" "VRAM" "Optimized for")

  # Show installed section
  if [[ ${#installed[@]} -gt 0 ]]; then
    echo -e "${BOLD}${GREEN}  Installed models${RESET}"
    echo -e "${DIM}  ─────────────────────────────────────────────────────────────────────────${RESET}"
    echo -e "$hdr"
    for m in "${installed[@]}"; do
      format_model_line "$idx" "$m" "${GREEN}" "[ready]"
      ((idx++))
    done
    echo ""
  else
    warn "No MLX models installed yet."
    echo ""
  fi

  # Show recommended section
  if [[ ${#available[@]} -gt 0 ]]; then
    echo -e "${BOLD}${YELLOW}  Recommended — general chat & code${RESET}"
    echo -e "${DIM}  ─────────────────────────────────────────────────────────────────────────${RESET}"
    echo -e "$hdr"
    for m in "${available[@]}"; do
      format_model_line "$idx" "$m" "${YELLOW}" "[download]"
      ((idx++))
    done
    echo ""
  fi

  # Show other/niche section
  if [[ ${#other[@]} -gt 0 ]]; then
    echo -e "${BOLD}${DIM}  Other — vision, reasoning variants, older/extreme sizes${RESET}"
    echo -e "${DIM}  ─────────────────────────────────────────────────────────────────────────${RESET}"
    echo -e "$hdr"
    for m in "${other[@]}"; do
      format_model_line "$idx" "$m" "${DIM}" "[download]"
      ((idx++))
    done
    echo ""
  fi

  local total=$((idx - 1))
  echo -e "${DIM}  Or type a Hugging Face model ID (e.g. mlx-community/Some-Model-4bit)${RESET}"
  echo ""

  # Read user choice
  while true; do
    echo -ne "${BOLD}  Select model [1-${total}] or ID: ${RESET}"
    read -r choice

    # If it looks like a HF model ID, use it directly
    if [[ "$choice" == */* ]]; then
      SELECTED_MODEL="$choice"
      return
    fi

    # Validate numeric choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= total )); then
      # Map index to model name
      local all_models=()
      for m in ${installed[@]+"${installed[@]}"}; do all_models+=("$m"); done
      for m in ${available[@]+"${available[@]}"}; do all_models+=("$m"); done
      for m in ${other[@]+"${other[@]}"}; do all_models+=("$m"); done
      SELECTED_MODEL="${all_models[$((choice - 1))]}"
      return
    fi

    err "Invalid selection. Try again."
  done
}

# ── Step 4: Choose mode ─────────────────────────────────────────────────────

choose_mode() {
  echo -e "${BOLD}${CYAN}  How do you want to use this model?${RESET}"
  echo -e "${DIM}  ─────────────────────────────────────────${RESET}"
  echo -e "  ${GREEN}1${RESET})  Terminal chat          ${DIM}— interactive conversation in this terminal${RESET}"
  echo -e "  ${GREEN}2${RESET})  Serve API for Copilot  ${DIM}— OpenAI-compatible server on localhost${RESET}"
  echo ""

  while true; do
    echo -ne "${BOLD}  Select mode [1-2]: ${RESET}"
    read -r mode_choice
    case "$mode_choice" in
      1) RUN_MODE="chat"; return ;;
      2) RUN_MODE="server"; return ;;
      *) err "Invalid selection. Enter 1 or 2." ;;
    esac
  done
}

# ── Step 5: Run the model ───────────────────────────────────────────────────

run_chat() {
  local model="$1"
  echo ""
  info "Loading ${BOLD}$model${RESET}..."
  echo -e "${DIM}  (First run will download the model weights — this can take a while)${RESET}"
  echo ""
  echo -e "${DIM}  Type your messages below. Press Ctrl+C to exit.${RESET}"
  echo -e "${DIM}  ─────────────────────────────────────────${RESET}"
  echo ""

  python3 -m mlx_lm chat \
    --model "$model" \
    --max-tokens 4096
}

run_server() {
  local model="$1"
  local port="${MLX_PORT:-8080}"
  echo ""
  info "Starting OpenAI-compatible API server..."
  echo ""
  echo -e "${BOLD}  Model:${RESET}    $model"
  echo -e "${BOLD}  Endpoint:${RESET}  http://localhost:${port}/v1/chat/completions"
  echo ""
  echo -e "${DIM}  ─────────────────────────────────────────${RESET}"
  echo -e "${BOLD}  VS Code Copilot configuration:${RESET}"
  echo ""
  echo -e "  Add to your ${CYAN}settings.json${RESET}:"
  echo ""
  echo -e "  ${DIM}{${RESET}"
  echo -e "  ${DIM}  \"github.copilot.chat.models\": [{${RESET}"
  echo -e "  ${DIM}    \"id\": \"mlx-local\",${RESET}"
  echo -e "  ${DIM}    \"family\": \"mlx-local\",${RESET}"
  echo -e "  ${DIM}    \"name\": \"MLX Local (${model##*/})\",${RESET}"
  echo -e "  ${DIM}    \"url\": \"http://localhost:${port}/v1/chat/completions\",${RESET}"
  echo -e "  ${DIM}    \"isDefault\": false,${RESET}"
  echo -e "  ${DIM}    \"sendHeaders\": {}${RESET}"
  echo -e "  ${DIM}  }]${RESET}"
  echo -e "  ${DIM}}${RESET}"
  echo ""
  echo -e "${DIM}  ─────────────────────────────────────────${RESET}"
  echo -e "${DIM}  Press Ctrl+C to stop the server.${RESET}"
  echo ""

  python3 -m mlx_lm server \
    --model "$model" \
    --port "$port"
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
  header
  ensure_deps
  echo ""
  show_menu
  echo ""
  choose_mode

  case "$RUN_MODE" in
    chat)   run_chat "$SELECTED_MODEL" ;;
    server) run_server "$SELECTED_MODEL" ;;
  esac
}

main "$@"
