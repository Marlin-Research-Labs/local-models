#!/bin/bash
# install-claude-local.sh: install claude-local (Claude Code on a local open-weight model).
# Automates INSTALL.md. No admin rights needed, and it never uses sudo. It is safe to
# re-run: finished steps are skipped, and existing configs are merged rather than replaced.
#
# Usage: ./install-claude-local.sh [--no-verify] [--memory-test] [--force] [--help]
#   --no-verify    install only; don't start the server or run the checks
#   --memory-test  also run the full-context memory test (1-2 minutes, ~27 GB)
#   --force        continue on a Mac that looks too small for this model

set -euo pipefail

OMLX_TAG="v0.7.0rc1"
MODEL_REPO="unsloth/Qwen3.6-35B-A3B-UD-MLX-4bit"
MODEL_DIR_NAME="Qwen3.6-35B-A3B-UD-MLX-4bit"
MODEL_ALIAS="qwen3.6-35b-a3b"
PORT=8765

APP="$HOME/Applications/oMLX.app"
OMLX_CLI="$APP/Contents/MacOS/omlx-cli"
OMLX_PY_ROOT="$APP/Contents/Resources/Python"
OMLX_HOME="$HOME/.omlx"
MODEL_DIR="$OMLX_HOME/models/$MODEL_DIR_NAME"
PROFILE="$HOME/.claude-local"
WRAPPER="$HOME/.local/bin/claude-local"
BASELINE="$HOME/claude-local-baseline"
DL_DIR="$HOME/Downloads/omlx"
JQ=/usr/bin/jq

verify=1
memory_test=0
force=0
for arg in "$@"; do
  case "$arg" in
    --no-verify) verify=0 ;;
    --memory-test) memory_test=1 ;;
    --force) force=1 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg (see --help)" >&2; exit 2 ;;
  esac
done

step() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    WARNING: %s\n' "$*" >&2; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# Run oMLX's bundled Python (has MLX; present once the app is installed).
omlx_py() {
  PYTHONHOME="$OMLX_PY_ROOT/cpython-3.11" \
  PYTHONPATH="$OMLX_PY_ROOT/framework-mlx-base/lib/python3.11/site-packages" \
    "$OMLX_PY_ROOT/cpython-3.11/bin/python3" "$@"
}

same_json() {  # same_json <a> <b>: true when both files hold the same JSON
  cmp -s <("$JQ" -S . "$1" 2>/dev/null) <("$JQ" -S . "$2" 2>/dev/null)
}

api() {  # api <path> <json-or-@file>: POST to the local server
  curl -sS -m 1200 "http://127.0.0.1:$PORT$1" -H "Authorization: Bearer local" \
    -H "content-type: application/json" -H "anthropic-version: 2023-06-01" -d "$2"
}

# ---------------------------------------------------------------------------
step "1/8 Checking this Mac"
[ "$(uname -m)" = "arm64" ] || die "Apple Silicon is required."
macos_ver=$(sw_vers -productVersion)
macos_major=${macos_ver%%.*}
[ "$macos_major" -ge 15 ] || die "macOS 15 or later is required (found $macos_ver)."
ram_gib=$(( $(sysctl -n hw.memsize) / 1073741824 ))
info "$(sysctl -n machdep.cpu.brand_string), $ram_gib GB memory, macOS $macos_ver"
if [ "$ram_gib" -lt 36 ]; then
  [ "$force" -eq 1 ] || die "This setup needs 36 GB of memory or more (found $ram_gib GB). Use --force to try anyway."
  warn "only $ram_gib GB of memory; continuing because of --force"
fi
[ -x "$JQ" ] || die "/usr/bin/jq not found (it ships with macOS 15 and later)."

CLAUDE_BIN="$HOME/.local/bin/claude"
[ -x "$CLAUDE_BIN" ] || CLAUDE_BIN="$(command -v claude || true)"
[ -n "$CLAUDE_BIN" ] || die "Claude Code not found. Install it first (https://code.claude.com/docs) and log in."
info "Claude Code: $CLAUDE_BIN ($("$CLAUDE_BIN" --version 2>/dev/null | head -1))"

have_model_gb=$(du -sg "$MODEL_DIR" 2>/dev/null | cut -f1 || true)
need_gb=$(( 30 - ${have_model_gb:-0} ))
free_gb=$(df -g "$HOME" | awk 'NR == 2 {print $4}')
[ "$free_gb" -ge "$need_gb" ] || die "Need about $need_gb GB of free disk space; only $free_gb GB free."
info "disk: $free_gb GB free"

pid=$(lsof -nP -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | head -1 || true)
if [ -n "$pid" ]; then
  case "$(ps -o command= -p "$pid" 2>/dev/null)" in
    *omlx*) info "port $PORT: oMLX already running (pid $pid)" ;;
    *) die "Port $PORT is used by another program (pid $pid). Free it and re-run." ;;
  esac
else
  info "port $PORT: free"
fi
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) warn "~/.local/bin is not on your PATH; add it to run claude-local by name." ;;
esac

if [ -f "$BASELINE/sha.txt" ]; then
  info "baseline of normal Claude Code already in $BASELINE"
else
  mkdir -p "$BASELINE"
  shasum -a 256 "$HOME/.claude/settings.json" "$HOME/.claude/CLAUDE.md" 2>/dev/null > "$BASELINE/sha.txt" || true
  "$CLAUDE_BIN" auth status > "$BASELINE/auth.txt" 2>&1 || true
  info "recorded a baseline of normal Claude Code in $BASELINE"
fi

# ---------------------------------------------------------------------------
step "2/8 Installing oMLX $OMLX_TAG into ~/Applications (INSTALL.md step 2)"
have_ver=$("$OMLX_CLI" --version 2>/dev/null || true)
if [ "$have_ver" = "${OMLX_TAG#v}" ]; then
  info "oMLX $have_ver is already installed at $APP"
else
  if [ "$macos_major" -ge 26 ]; then flavor="macos26-27"; else flavor="macos15-sequoia"; fi
  asset=$(curl -fsSL "https://api.github.com/repos/jundot/omlx/releases/tags/$OMLX_TAG" \
    | "$JQ" -r --arg f "$flavor" '.assets[] | select(.name | endswith($f + ".dmg")) | "\(.browser_download_url) \(.digest)"') \
    || die "Could not look up oMLX $OMLX_TAG on GitHub."
  [ -n "$asset" ] || die "oMLX $OMLX_TAG has no $flavor DMG."
  dmg_url=${asset%% *}
  dmg_sha=${asset##*sha256:}
  mkdir -p "$DL_DIR"
  dmg="$DL_DIR/omlx-$OMLX_TAG-$flavor.dmg"
  if ! echo "$dmg_sha  $dmg" | shasum -a 256 -c - >/dev/null 2>&1; then
    info "downloading $dmg_url"
    curl -fL --retry 3 -C - -o "$dmg" "$dmg_url" || curl -fL --retry 3 -o "$dmg" "$dmg_url"
    echo "$dmg_sha  $dmg" | shasum -a 256 -c - >/dev/null 2>&1 \
      || die "Checksum mismatch for $dmg. Delete it and re-run."
  fi
  info "download verified (SHA-256 $dmg_sha)"

  mnt=$(mktemp -d)
  hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$dmg" >/dev/null 2>&1 || die "Could not mount $dmg."
  trap 'hdiutil detach "$mnt" >/dev/null 2>&1 || true' EXIT
  codesign --verify --deep --strict "$mnt/oMLX.app" 2>/dev/null || die "oMLX.app failed its code-signature check."
  spctl -a -t exec "$mnt/oMLX.app" 2>/dev/null || die "Gatekeeper did not accept oMLX.app (not notarized?)."
  info "signed and notarized: $(codesign -dv --verbose=2 "$mnt/oMLX.app" 2>&1 | sed -n 's/^Authority=\(Developer ID Application.*\)/\1/p')"

  # Stop claude-local's server before replacing the app it runs from.
  if [ -x "$WRAPPER" ] && [ -d "$APP" ]; then "$WRAPPER" --local-stop >/dev/null 2>&1 || true; fi
  mkdir -p "$HOME/Applications"
  rm -rf "$APP.new"
  ditto "$mnt/oMLX.app" "$APP.new"
  rm -rf "$APP"
  mv "$APP.new" "$APP"
  hdiutil detach "$mnt" >/dev/null 2>&1 || true
  trap - EXIT
  info "installed oMLX $("$OMLX_CLI" --version) at $APP"
  info "(don't open it from Finder; claude-local runs its server headless)"
fi

# ---------------------------------------------------------------------------
step "3/8 Downloading the model $MODEL_REPO (INSTALL.md step 3)"
mkdir -p "$MODEL_DIR"
curl -fsSL "https://huggingface.co/api/models/$MODEL_REPO/tree/main?recursive=true" \
  | "$JQ" -r '.[] | select(.type == "file" and .path != ".gitattributes") | "\(.path) \(.lfs.size // .size)"' \
  > "$MODEL_DIR/.filelist" || die "Could not list the model files on Hugging Face."
failed=0
while read -r f sz; do
  out="$MODEL_DIR/$f"
  mkdir -p "$(dirname "$out")"
  for try in 1 2 3 4 5; do
    [ "$(stat -f %z "$out" 2>/dev/null || echo 0)" = "$sz" ] && break
    info "downloading $f ($(( sz / 1000000 )) MB), attempt $try"
    curl -fL --retry 5 --retry-delay 5 -C - -o "$out" "https://huggingface.co/$MODEL_REPO/resolve/main/$f" || true
  done
  if [ "$(stat -f %z "$out" 2>/dev/null || echo 0)" = "$sz" ]; then
    info "OK   $f"
  else
    warn "FAIL $f"
    failed=1
  fi
done < "$MODEL_DIR/.filelist"
[ "$failed" -eq 0 ] || die "Some model files did not download. Re-run to resume."

# ---------------------------------------------------------------------------
step "4/8 Sizing for this Mac's GPU memory budget (INSTALL.md step 7)"
budget=$(omlx_py -c "import mlx.core as mx; print(round(mx.device_info()['max_recommended_working_set_size'] / 2**30, 1))") \
  || die "Could not read the GPU memory budget with oMLX's bundled Python."
info "GPU budget: $budget GiB (the model's weights take 19.7 GB)"
if awk -v b="$budget" 'BEGIN { exit !(b >= 34) }'; then
  tier="balanced"
elif awk -v b="$budget" 'BEGIN { exit !(b >= 27) }'; then
  tier="aggressive"
else
  [ "$force" -eq 1 ] || die "A $budget GiB GPU budget is too small for this model at the context Claude Code needs. Use --force to try anyway."
  tier="aggressive"
  warn "budget below 27 GiB; long prompts will be rejected. Consider CLAUDE_LOCAL_CTX=65536 CLAUDE_LOCAL_MAX_OUT=16384."
fi
info "memory guard tier: $tier, Claude Code context window: 131072"

# ---------------------------------------------------------------------------
step "5/8 Configuring oMLX (INSTALL.md step 4)"
mkdir -p "$OMLX_HOME"
settings="$OMLX_HOME/settings.json"
models="$OMLX_HOME/model_settings.json"
# Keep one copy of any config that existed before claude-local configured it.
if [ -f "$settings" ] && [ ! -e "$settings.pre-claude-local" ] \
   && ! "$JQ" -e --argjson p "$PORT" '.server.port == $p and .scheduler.max_concurrent_requests == 1' "$settings" >/dev/null 2>&1; then
  cp "$settings" "$settings.pre-claude-local"
  info "saved your previous settings.json as settings.json.pre-claude-local"
fi
if [ -f "$models" ] && [ ! -e "$models.pre-claude-local" ] \
   && ! "$JQ" -e --arg k "$MODEL_DIR_NAME" --arg a "$MODEL_ALIAS" '.models[$k].model_alias == $a' "$models" >/dev/null 2>&1; then
  cp "$models" "$models.pre-claude-local"
  info "saved your previous model_settings.json as model_settings.json.pre-claude-local"
fi
[ -f "$settings" ] || echo '{"version": "1.0"}' > "$settings"
[ -f "$models" ] || echo '{"version": 1, "models": {}}' > "$models"

tmp=$(mktemp)
"$JQ" --argjson port "$PORT" --arg tier "$tier" '
    .version //= "1.0"
  | .server.host = "127.0.0.1" | .server.port = $port | .server.log_level //= "info"
  | .scheduler.max_concurrent_requests = 1
  | .cache.enabled = true | .cache.ssd_cache_max_size = "50GB" | .cache.hot_cache_max_size = "0"
  | .memory.prefill_memory_guard = true | .memory.memory_guard_tier = $tier
  | .sampling.max_context_window = 163840 | .sampling.max_tokens = 32768
  ' "$settings" > "$tmp"
config_changed=0
if same_json "$tmp" "$settings"; then
  info "settings.json is up to date"
  rm -f "$tmp"
else
  config_changed=1
  mv "$tmp" "$settings"
  info "updated $settings"
fi

model_entry=$(cat <<'MODEL_ENTRY'
{
  "model_alias": "qwen3.6-35b-a3b",
  "display_name": "Qwen3.6-35B-A3B (Unsloth UD-MLX-4bit)",
  "max_context_window": 163840,
  "max_tokens": 32768,
  "temperature": 0.6,
  "top_p": 0.95,
  "top_k": 20,
  "min_p": 0.0,
  "presence_penalty": 0.0,
  "repetition_penalty": 1.0,
  "enable_thinking": true,
  "preserve_thinking": true,
  "ttl_seconds": 1800,
  "is_default": true,
  "model_type_override": "llm"
}
MODEL_ENTRY
)
tmp=$(mktemp)
"$JQ" --arg k "$MODEL_DIR_NAME" --argjson e "$model_entry" \
  '.version //= 1 | .models[$k] = ((.models[$k] // {}) + $e)' "$models" > "$tmp"
if same_json "$tmp" "$models"; then
  info "model_settings.json is up to date"
  rm -f "$tmp"
else
  config_changed=1
  mv "$tmp" "$models"
  info "updated $models"
fi

# ---------------------------------------------------------------------------
step "6/8 Creating the isolated Claude Code profile ~/.claude-local (INSTALL.md step 5)"
mkdir -p "$PROFILE"
if [ -e "$HOME/.claude/CLAUDE.md" ] && [ ! -e "$PROFILE/CLAUDE.md" ]; then
  ln -s "$HOME/.claude/CLAUDE.md" "$PROFILE/CLAUDE.md"
  info "linked ~/.claude-local/CLAUDE.md -> ~/.claude/CLAUDE.md"
fi
if [ -e "$PROFILE/settings.json" ]; then
  info "~/.claude-local/settings.json already exists; leaving it alone"
else
  { [ -f "$HOME/.claude/settings.json" ] && cat "$HOME/.claude/settings.json" || echo '{}'; } \
    | "$JQ" '{cleanupPeriodDays, theme, hooks} | with_entries(select(.value != null))
        + {effortLevel: "medium", useAutoModeDuringPlan: false, disableClaudeAiConnectors: true,
           permissions: {defaultMode: "default"}}' > "$PROFILE/settings.json"
  info "wrote ~/.claude-local/settings.json (theme and hooks copied from ~/.claude/settings.json)"
fi

# ---------------------------------------------------------------------------
step "7/8 Installing the claude-local wrapper (INSTALL.md step 6)"
mkdir -p "$(dirname "$WRAPPER")"
new=$(mktemp)
cat > "$new" <<'CLAUDE_LOCAL_SCRIPT'
#!/bin/bash
# claude-local: run Claude Code against a local open-weight model.
#
# Default backend: oMLX (~/Applications/oMLX.app) serving Qwen3.6-35B-A3B
# (Unsloth UD-MLX-4bit) on http://127.0.0.1:8765. Fallback backend: Ollama.
#
# Everything here is scoped to this process. It never edits ~/.claude,
# ~/.claude.json, shell rc files or launchd, so the normal `claude` command
# keeps its own login, settings and history. Claude Code state for local
# sessions lives in ~/.claude-local (CLAUDE_CONFIG_DIR).
#
# Org-managed settings (MintMCP hooks, OTEL telemetry) still apply here by
# design; nothing in this script bypasses them.
#
# Wrapper-only commands (first argument):
#   --local-status   show server, model and memory warnings
#   --local-start    start the server and load the model, then exit
#   --local-stop     stop the oMLX server started by claude-local
#   --local-help     show this help
#
# Overrides (environment, per invocation):
#   CLAUDE_LOCAL_BACKEND  omlx (default) | ollama
#   CLAUDE_LOCAL_MODEL    model id served by the backend
#   CLAUDE_LOCAL_PORT     backend port (oMLX 8765, Ollama 11434)
#   CLAUDE_LOCAL_CTX      context window Claude Code plans for (default 131072)
#   CLAUDE_LOCAL_MAX_OUT  max output tokens per response (default 32000)

set -euo pipefail

warn() { echo "claude-local: warning: $*" >&2; }
die() { echo "claude-local: $*" >&2; exit 1; }

# Native installer symlink (follows updates); fall back to whatever claude is on PATH.
CLAUDE_BIN="$HOME/.local/bin/claude"
[ -x "$CLAUDE_BIN" ] || CLAUDE_BIN="$(command -v claude || true)"
[ -n "$CLAUDE_BIN" ] || die "Claude Code not found (expected ~/.local/bin/claude)"

# oMLX.app in ~/Applications (no admin needed), else /Applications.
OMLX_APP="$HOME/Applications/oMLX.app"
[ -d "$OMLX_APP" ] || [ ! -d /Applications/oMLX.app ] || OMLX_APP="/Applications/oMLX.app"
OMLX_CLI="$OMLX_APP/Contents/MacOS/omlx-cli"
OMLX_HOME="$HOME/.omlx"
OMLX_LOG="$OMLX_HOME/logs/claude-local-server.log"
OMLX_PIDFILE="$OMLX_HOME/claude-local-server.pid"
LOCAL_CONFIG_DIR="$HOME/.claude-local"

backend="${CLAUDE_LOCAL_BACKEND:-omlx}"
case "$backend" in
  omlx)
    port="${CLAUDE_LOCAL_PORT:-8765}"
    model="${CLAUDE_LOCAL_MODEL:-qwen3.6-35b-a3b}"
    token="local"
    ;;
  ollama)
    port="${CLAUDE_LOCAL_PORT:-11434}"
    model="${CLAUDE_LOCAL_MODEL:-qwen3.6:35b-a3b-coding-nvfp4}"
    token="ollama"
    ;;
  *)
    echo "claude-local: unknown CLAUDE_LOCAL_BACKEND '$backend' (use omlx or ollama)" >&2
    exit 2
    ;;
esac
base_url="http://127.0.0.1:$port"
ctx="${CLAUDE_LOCAL_CTX:-131072}"
max_out="${CLAUDE_LOCAL_MAX_OUT:-32000}"

# True when the backend answers and lists $model.
server_has_model() {
  curl -fsS -m 3 -H "Authorization: Bearer $token" "$base_url/v1/models" 2>/dev/null \
    | /usr/bin/jq -e --arg m "$model" 'any(.data[]?; .id == $m)' >/dev/null 2>&1
}

port_listener_pid() {
  lsof -nP -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null | head -1 || true
}

# Two ~20 GB models cannot share 36 GB, and OrbStack's VM holds ~13 GB.
memory_warnings() {
  if command -v orbctl >/dev/null 2>&1 && [ "$(orbctl status 2>/dev/null)" = "Running" ]; then
    warn "OrbStack is running (its VM can hold ~13 GB). Stop it with 'orbctl stop' for best performance."
  fi
  if [ "$backend" != "ollama" ]; then
    local n
    n=$(curl -fsS -m 2 http://127.0.0.1:11434/api/ps 2>/dev/null | /usr/bin/jq '.models | length' 2>/dev/null || echo 0)
    [ "${n:-0}" -gt 0 ] && warn "Ollama has $n model(s) loaded; unload them with 'ollama stop <model>'."
  fi
  if command -v lms >/dev/null 2>&1; then
    local m
    m=$(lms ps --json 2>/dev/null | /usr/bin/jq 'length' 2>/dev/null || echo 0)
    [ "${m:-0}" -gt 0 ] && warn "LM Studio has $m model(s) loaded; unload them with 'lms unload --all'."
  fi
  return 0
}

start_omlx() {
  [ -x "$OMLX_CLI" ] || die "oMLX not found at $OMLX_CLI"
  local pid
  pid=$(port_listener_pid)
  if [ -n "$pid" ]; then
    die "port $port is in use by pid $pid, but it does not serve '$model'. Check it with: lsof -nP -iTCP:$port"
  fi
  mkdir -p "$(dirname "$OMLX_LOG")"
  echo "claude-local: starting oMLX on $base_url (log: $OMLX_LOG)" >&2
  # Own process group (set -m) so Ctrl-C in Claude Code never reaches the server.
  ( set -m; nohup "$OMLX_CLI" serve --port "$port" </dev/null >>"$OMLX_LOG" 2>&1 &
    echo $! >"$OMLX_PIDFILE" )
  local i=0
  until server_has_model; do
    i=$((i + 1))
    if [ "$i" -ge 90 ]; then
      die "oMLX did not list '$model' within 90 s; see $OMLX_LOG"
    fi
    if ! kill -0 "$(cat "$OMLX_PIDFILE" 2>/dev/null)" 2>/dev/null; then
      die "oMLX exited during startup; see $OMLX_LOG"
    fi
    sleep 1
  done
}

stop_omlx() {
  local pid
  pid=$(cat "$OMLX_PIDFILE" 2>/dev/null || true)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || pid=$(port_listener_pid)
  if [ -z "$pid" ]; then
    echo "claude-local: oMLX is not running on port $port"
    rm -f "$OMLX_PIDFILE"
    return 0
  fi
  case "$(ps -o command= -p "$pid" 2>/dev/null)" in
    *omlx*) ;;
    *) die "pid $pid on port $port is not oMLX; not stopping it" ;;
  esac
  kill -TERM "$pid" 2>/dev/null || true
  local i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 20 ]; do sleep 1; i=$((i + 1)); done
  # The server can linger holding GPU memory (oMLX #3431); force it if needed.
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
  rm -f "$OMLX_PIDFILE"
  echo "claude-local: oMLX stopped"
}

# Ask the server to load the model now, so the first Claude Code turn
# doesn't also pay the ~20 GB load time.
warm_model() {
  curl -fsS -m 600 -H "Authorization: Bearer $token" -H "content-type: application/json" \
    -H "anthropic-version: 2023-06-01" "$base_url/v1/messages" \
    -d "{\"model\":\"$model\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"thinking\":{\"type\":\"disabled\"}}" \
    >/dev/null
}

case "${1:-}" in
  --local-help)
    sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  --local-status)
    echo "backend: $backend  url: $base_url  model: $model  context: $ctx  max output: $max_out"
    echo "claude: $CLAUDE_BIN  omlx: $OMLX_CLI"
    if server_has_model; then echo "server: up, '$model' available"; else echo "server: down or '$model' not listed"; fi
    memory_warnings
    exit 0
    ;;
  --local-stop)
    [ "$backend" = "omlx" ] || die "--local-stop only manages oMLX; quit Ollama from its menu-bar app"
    stop_omlx
    exit 0
    ;;
  --local-start)
    memory_warnings
    if ! server_has_model; then
      [ "$backend" = "omlx" ] || die "Ollama is not serving '$model' at $base_url"
      start_omlx
    fi
    echo "claude-local: loading '$model'..." >&2
    warm_model || die "the model failed to load; see $OMLX_LOG"
    echo "claude-local: ready at $base_url"
    exit 0
    ;;
esac

memory_warnings
if ! server_has_model; then
  if [ "$backend" = "omlx" ]; then
    start_omlx
  else
    die "Ollama is not serving '$model' at $base_url (is the Ollama app running?)"
  fi
fi

[ -d "$LOCAL_CONFIG_DIR" ] || mkdir -p "$LOCAL_CONFIG_DIR"

# Drop anything that could route or authenticate elsewhere.
unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_PROFILE ANTHROPIC_BETAS \
  ANTHROPIC_SMALL_FAST_MODEL CLAUDE_CODE_SIMPLE CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX \
  CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_MANTLE CLAUDE_CODE_USE_GATEWAY \
  CLAUDE_CODE_USE_ANTHROPIC_AWS CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD \
  CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT \
  CLAUDE_CODE_AUTO_COMPACT_WINDOW CLAUDE_SECURESTORAGE_CONFIG_DIR

# Isolated profile and local endpoint.
export CLAUDE_CONFIG_DIR="$LOCAL_CONFIG_DIR"
export ANTHROPIC_BASE_URL="$base_url"
export ANTHROPIC_AUTH_TOKEN="$token"

# Every model tier maps to the one loaded model.
export ANTHROPIC_MODEL="$model" CLAUDE_CODE_SUBAGENT_MODEL="$model"
export ANTHROPIC_DEFAULT_FABLE_MODEL="$model" ANTHROPIC_DEFAULT_OPUS_MODEL="$model"
export ANTHROPIC_DEFAULT_SONNET_MODEL="$model" ANTHROPIC_DEFAULT_HAIKU_MODEL="$model"

# Context: Claude Code assumes 200K for unknown models; declare the real window.
export CLAUDE_CODE_MAX_CONTEXT_TOKENS="$ctx" CLAUDE_CODE_MAX_OUTPUT_TOKENS="$max_out"

# Keep the prompt prefix stable so the server's prefix cache hits.
export CLAUDE_CODE_ATTRIBUTION_HEADER=0 CLAUDE_CODE_TOTAL_TOKENS_REMINDER=off

# Compatibility with a non-Anthropic backend.
export CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1 ENABLE_CLAUDEAI_MCP_SERVERS=false
export CLAUDE_CODE_DISABLE_FAST_MODE=1 CLAUDE_CODE_AUTO_MODE_SERVER=0
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

# One server slot: no background side requests or parallel subagents.
export CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=1 CLAUDE_CODE_ENABLE_AWAY_SUMMARY=0
export CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false
export CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL=1

# Local prefill of long prompts can take minutes.
export API_TIMEOUT_MS=3000000 CLAUDE_STREAM_FIRST_BYTE_TIMEOUT_MS=1800000
export CLAUDE_BYTE_STREAM_IDLE_TIMEOUT_MS=600000

# Claude Code subcommands (mcp, doctor, update, ...) take no session flags.
case "${1:-}" in
  agents|attach|auth|auto-mode|doctor|gateway|import|install|logs|mcp|plugin|plugins|project|respawn|rm|setup-token|stop|kill|ultrareview|update|upgrade)
    exec "$CLAUDE_BIN" "$@"
    ;;
esac

# WebSearch is an Anthropic server-side tool; LSP schema changes break the prefix cache.
exec "$CLAUDE_BIN" --strict-mcp-config --exclude-dynamic-system-prompt-sections \
  --disallowedTools=WebSearch,LSP "$@"
CLAUDE_LOCAL_SCRIPT
bash -n "$new" || die "internal error: the embedded wrapper has a syntax error"
if [ -f "$WRAPPER" ] && cmp -s "$new" "$WRAPPER"; then
  info "$WRAPPER is up to date"
  rm -f "$new"
else
  if [ -f "$WRAPPER" ]; then
    backup="$WRAPPER.bak-$(date +%Y%m%d-%H%M%S)"
    cp -p "$WRAPPER" "$backup"
    info "backed up the previous wrapper to $backup"
  fi
  mv "$new" "$WRAPPER"
  info "installed $WRAPPER"
fi
chmod 755 "$WRAPPER"

# ---------------------------------------------------------------------------
if [ "$verify" -eq 0 ]; then
  step "8/8 Skipping checks (--no-verify)"
  info "Start with: claude-local --local-start, then claude-local"
  exit 0
fi

step "8/8 Checking the install (INSTALL.md step 8)"
problems=0
pass() { info "PASS $*"; }
fail() { warn "FAIL $*"; problems=$((problems + 1)); }

if command -v orbctl >/dev/null 2>&1 && [ "$(orbctl status 2>/dev/null)" = "Running" ]; then
  warn "OrbStack is running and can hold ~13 GB; 'orbctl stop' before long sessions"
fi
if [ "$config_changed" -eq 1 ] && [ -n "${pid:-}" ]; then
  warn "oMLX was already running with older settings. Run 'claude-local --local-stop' when no session is using it, then re-run this script."
fi

info "starting the server and loading the model (about 10-15 s the first time)"
if "$WRAPPER" --local-start >/dev/null; then pass "server up at http://127.0.0.1:$PORT with $MODEL_ALIAS"; else fail "server did not start; see ~/.omlx/logs/claude-local-server.log"; fi

answer=$(api /v1/messages '{"model":"'"$MODEL_ALIAS"'","max_tokens":2000,"thinking":{"type":"adaptive"},"messages":[{"role":"user","content":"What is 17*23? Answer with just the number."}]}' \
  | "$JQ" -r '[.content[]? | select(.type == "text") | .text] | join("")' 2>/dev/null || true)
case "$answer" in *391*) pass "API answers correctly (17*23 = 391)" ;; *) fail "API check: expected 391, got '$answer'" ;; esac

call=$(api /v1/messages '{"model":"'"$MODEL_ALIAS"'","max_tokens":4000,"thinking":{"type":"adaptive"},"tools":[{"name":"Bash","description":"Run a shell command.","input_schema":{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}}],"messages":[{"role":"user","content":"List the files in /tmp using the Bash tool."}]}' \
  | "$JQ" -r '"\(.stop_reason) \([.content[]? | select(.type == "tool_use") | .name] | join(","))"' 2>/dev/null || true)
case "$call" in "tool_use Bash"*) pass "tool calling works" ;; *) fail "tool-call check: got '$call'" ;; esac

testdir=$(mktemp -d)
reply=$(cd "$testdir" && "$WRAPPER" -p "Reply with exactly the word OK and nothing else." 2>&1 || true)
case "$reply" in *OK*) pass "claude-local -p works" ;; *) fail "claude-local -p: $(printf '%s' "$reply" | tail -3)" ;; esac
rm -rf "$testdir"

if [ "$memory_test" -eq 1 ]; then
  info "memory test: one prompt at Claude Code's largest size for a 131072 window (~108K tokens)"
  long=$(mktemp)
  expected=$(omlx_py - 131072 "$long" <<'PY'
import glob, json, os, sys, sysconfig
target = int((int(sys.argv[1]) - 23000) * 3.8)
text = ""
for f in sorted(glob.glob(os.path.join(sysconfig.get_paths()["stdlib"], "*.py"))):
    text += f"\n##### FILE: {os.path.basename(f)}\n" + open(f, encoding="utf-8", errors="replace").read()
    if len(text) >= target:
        break
text = text[:target]
last = text[text.rindex("##### FILE: ") + 12:].split("\n", 1)[0]
q = "\n\nQuestion: What is the file name in the very last '##### FILE:' header above? Reply with only the file name."
json.dump({"model": "qwen3.6-35b-a3b", "max_tokens": 200, "thinking": {"type": "disabled"},
           "messages": [{"role": "user", "content": text + q}]}, open(sys.argv[2], "w"))
print(last)
PY
)
  start=$(date +%s)
  result=$(api /v1/messages "@$long" | "$JQ" -r '.content[0].text // .error.message // "no response"' 2>/dev/null || true)
  secs=$(( $(date +%s) - start ))
  peak=$(footprint -p "$(cat "$OMLX_HOME/claude-local-server.pid" 2>/dev/null)" 2>/dev/null | awk '/phys_footprint_peak:/ {print $2, $3}')
  if [ "$result" = "$expected" ]; then pass "memory test answered correctly in $secs s (server peak ${peak:-unknown})"; else fail "memory test: expected '$expected', got '$result' (see INSTALL.md step 7)"; fi
  rm -f "$long"
fi

if shasum -a 256 "$HOME/.claude/settings.json" "$HOME/.claude/CLAUDE.md" 2>/dev/null | diff -q - "$BASELINE/sha.txt" >/dev/null; then
  pass "normal Claude Code settings unchanged"
else
  fail "normal Claude Code settings differ from the baseline in $BASELINE"
fi
if "$CLAUDE_BIN" auth status 2>&1 | diff -q - "$BASELINE/auth.txt" >/dev/null; then
  pass "normal Claude Code login unchanged"
else
  fail "normal Claude Code login differs from the baseline in $BASELINE"
fi

echo
if [ "$problems" -eq 0 ]; then
  echo "claude-local is installed and working."
else
  echo "claude-local is installed, but $problems check(s) failed. See INSTALL.md, Troubleshooting."
fi
cat <<'NEXT'

Next:
  claude-local                  interactive session (the first run asks for a theme and folder trust)
  claude-local --local-status   server, model and memory warnings
  claude-local --local-stop     stop the server and free ~20 GB
In a session, /context should show about 16K of 131.1K tokens used.
NEXT
[ "$problems" -eq 0 ]
