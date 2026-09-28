#!/bin/bash
# install-claude-local.sh: install claude-local (Claude Code on a local open-weight model).
# Automates INSTALL.md. No admin rights needed, and it never uses sudo. It is safe to
# re-run: finished steps are skipped, and existing configs are merged rather than replaced.
#
# Usage: ./install-claude-local.sh [--with-quality] [--with-laguna] [--with-all] [--no-verify]
#                                  [--memory-test] [--restart-server] [--force] [--help]
#   --with-quality  also install the quality model, Qwen3.8-27B (17-24 GB)
#   --with-laguna   also install Laguna: XS 2.1 on 36 GB Macs (20 GB), S 2.1 on 96 GB
#                   and up (64 GB); installed anyway on 96 GB and up, where it is the default
#   --with-all      every model this Mac can run
#   --no-verify     install only; don't start the server or run the checks
#   --memory-test   also test every installed model, with and without vision, at
#                   its full context window, stepping down until one fits, and
#                   record the result for this Mac (minutes per model; restarts the server)
#   --restart-server  restart the server (to load new models or settings) and run
#                   the memory test even if another session seems to be using it
#   --force         continue on a Mac with less than 16 GB of memory
# CLAUDE_LOCAL_PORT=<port> uses another port than 8765 (for testing, with another HOME).
# The models depend on the Mac's memory; claude-local --local-status lists them.
# Models already installed are kept up to date on re-runs.

set -euo pipefail

OMLX_TAG="v0.7.0rc1"
PORT="${CLAUDE_LOCAL_PORT:-8765}"

APP="$HOME/Applications/oMLX.app"
OMLX_CLI="$APP/Contents/MacOS/omlx-cli"
OMLX_PY_ROOT="$APP/Contents/Resources/Python"
OMLX_HOME="$HOME/.omlx"
PROFILE="$HOME/.claude-local"
WRAPPER="$HOME/.local/bin/claude-local"
BASELINE="$HOME/claude-local-baseline"
DL_DIR="$HOME/Downloads/omlx"
WINDOWS_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/claude-local/windows"
JQ=/usr/bin/jq
if [ "$PORT" = "8765" ]; then SERVER_PIDFILE="$OMLX_HOME/claude-local-server.pid"
else SERVER_PIDFILE="$OMLX_HOME/claude-local-server-$PORT.pid"; fi

# Laguna XS 2.1's own chat template has no preserve_thinking flag, so oMLX
# pastes earlier thinking into the message text and the history renders with
# two think blocks. Poolside's Laguna S 2.1 template is the same format with
# the flag, so it replaces the XS one.
XS_TEMPLATE_URL="https://huggingface.co/poolside/Laguna-S-2.1/resolve/0f573140834b11cfac0c2af97a101a7a69a13e22/chat_template.jinja"
XS_TEMPLATE_SHA="444819b8ad4612870827ac05b9147fe9e3344d3850cae8c2790898fc514099ff"

verify=1
memory_test=0
force=0
restart_server=0
with_quality=0
with_laguna=0
for arg in "$@"; do
  case "$arg" in
    --with-quality) with_quality=1 ;;
    --with-laguna) with_laguna=1 ;;
    --with-all) with_quality=1; with_laguna=1 ;;
    --no-verify) verify=0 ;;
    --memory-test) memory_test=1 ;;
    --force) force=1 ;;
    --restart-server) restart_server=1 ;;
    -h|--help) awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
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

# Hashes of the normal Claude Code settings; a missing file is simply left out.
settings_sha() {
  shasum -a 256 "$HOME/.claude/settings.json" "$HOME/.claude/CLAUDE.md" 2>/dev/null || true
}

api() {  # api <path> <json-or-@file>: POST to the local server
  curl -sS -m 2400 "http://127.0.0.1:$PORT$1" -H "Authorization: Bearer local" \
    -H "content-type: application/json" -H "anthropic-version: 2023-06-01" -d "$2"
}

installed() { [ -f "$OMLX_HOME/models/$1/config.json" ]; }

# The claude-local wrapper this script installs. It also knows which models
# fit this Mac (claude-local --local-catalog), so write it out first.
NEW_WRAPPER=$(mktemp)
trap 'rm -f "$NEW_WRAPPER"' EXIT
cat > "$NEW_WRAPPER" <<'CLAUDE_LOCAL_SCRIPT'
#!/bin/bash
# claude-local: run Claude Code against a local open-weight model.
#
# Models are served by oMLX (~/Applications/oMLX.app) on http://127.0.0.1:8765
# and picked for the Mac's memory (see claude-local --local-status):
#   fast     Qwen: Qwen3.6-35B-A3B (36 GB and up) or Qwen3.5-9B (16 GB Macs)
#   quality  Qwen3.8-27B, slower but stronger (36 GB and up)
#   laguna   Poolside Laguna: XS 2.1 (36 GB Macs) or S 2.1 (96 GB and up)
# Install extra models with install-claude-local.sh --with-quality, --with-laguna
# or --with-all. Qwen models can run with image input (vision) on or off (the
# default); Laguna is text only.
#
# Everything here is scoped to this process. It never edits ~/.claude,
# ~/.claude.json, shell rc files or launchd, so the normal `claude` command
# keeps its own login, settings and history. Claude Code state for local
# sessions lives in ~/.claude-local (CLAUDE_CONFIG_DIR).
#
# Org-managed settings (MintMCP hooks, OTEL telemetry) still apply here by
# design; nothing in this script bypasses them.
#
# Wrapper options (they must come before any Claude Code arguments):
#   --local-fast | --local-quality | --local-laguna   choose the model
#   --local-vision | --local-no-vision   image input on or off (default: off)
#   --local-set-default   save the model and vision options given, then exit
#   --local-status        show this Mac's models, the selection and the server
#   --local-start         start the server and load the selected model, then exit
#   --local-stop          stop the oMLX server started by claude-local
#   --local-help          show this help
# The default model is fast, or laguna on Macs with 96 GB or more.
#
# Environment, per invocation: CLAUDE_LOCAL_PROFILE=fast|quality|laguna and
# CLAUDE_LOCAL_VISION=on|off. For experiments: CLAUDE_LOCAL_MODEL (served model
# id), CLAUDE_LOCAL_CTX, CLAUDE_LOCAL_MAX_OUT, CLAUDE_LOCAL_PORT,
# CLAUDE_LOCAL_LEAN=on|off (a smaller tool set; on by default on 16 GB Macs),
# CLAUDE_LOCAL_MACHINE=16|36|96|128 (the memory class) and
# CLAUDE_LOCAL_BACKEND=omlx|ollama.
#
# Precedence: option > environment > saved default > built-in. Saved defaults
# live in ~/.config/claude-local/defaults (or $XDG_CONFIG_HOME/claude-local);
# context windows measured on this Mac (install-claude-local.sh --memory-test)
# in the windows file next to it.

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
LOCAL_CONFIG_DIR="$HOME/.claude-local"
DEFAULTS_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/claude-local/defaults"
WINDOWS_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/claude-local/windows"

# --- Wrapper options: a leading run of --local-* arguments ------------------
opt_profile=""
opt_vision=""
cmd=""
while [ $# -gt 0 ]; do
  case "$1" in
    --local-fast) opt_profile=fast ;;
    --local-quality) opt_profile=quality ;;
    --local-laguna) opt_profile=laguna ;;
    --local-vision) opt_vision=on ;;
    --local-no-vision) opt_vision=off ;;
    --local-status|--local-start|--local-stop|--local-help|--local-set-default|--local-catalog)
      [ -z "$cmd" ] || die "one of --local-status/start/stop/help/set-default at a time"
      cmd="${1#--local-}" ;;
    --local-*) echo "claude-local: unknown option '$1' (see claude-local --local-help)" >&2; exit 2 ;;
    *) break ;;
  esac
  shift
done

if [ "$cmd" = "help" ]; then
  awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"
  exit 0
fi

# --- This Mac's memory class ------------------------------------------------
# The models and context windows depend on how much memory the GPU may use,
# which macOS derives from the RAM size.
ram_gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))
case "${CLAUDE_LOCAL_MACHINE:-}" in
  "")
    if [ "$ram_gb" -ge 128 ]; then class=128
    elif [ "$ram_gb" -ge 96 ]; then class=96
    elif [ "$ram_gb" -ge 36 ]; then class=36
    else class=16; fi
    class_src="$ram_gb GB" ;;
  16|36|96|128) class=$CLAUDE_LOCAL_MACHINE; class_src="CLAUDE_LOCAL_MACHINE; this Mac has $ram_gb GB" ;;
  *) die "CLAUDE_LOCAL_MACHINE must be 16, 36, 96 or 128" ;;
esac
case "$class" in
  96|128) class_default=laguna ;;
  *) class_default=fast ;;
esac

# The model for each role on each class of Mac. catalog <profile> sets:
#   repo, rev   Hugging Face repository and pinned revision
#   base        model folder under ~/.omlx/models; its vision variant (if any)
#               is the symlink <base>-vision, served by oMLX's vision engine
#   base_alias  served model id (never starting with claude-); vision: <alias>-vision
#   gb          download size, GB
#   text_ctx    context window Claude Code plans for, text only
#   vision_ctx  the same with vision on; empty when the model has no image input
#   row_out     max output tokens
#   caps        extra Claude Code capability flags
#   measured    yes when the windows were measured on such a Mac with
#               install-claude-local.sh --memory-test, no for estimates
# A role that doesn't fit this class sets base="" and why.
catalog() {
  repo="" rev="" base="" base_alias="" gb=0 text_ctx=0 vision_ctx="" row_out=32000 caps="" measured=no why=""
  case "$class:$1" in
    16:fast)
      repo=craquehouse/Qwen3.5-9B-oQ4e-fp16-text-only; rev=61b16465e2c70e58995a79a25fc40216a37984c0
      base=Qwen3.5-9B-oQ4e-fp16-text-only; base_alias=qwen3.5-9b; gb=6
      text_ctx=65536; row_out=8192; caps="-mid_conv_system" ;;
    16:quality) why="no quality model fits in a 16 GB Mac; the fast model (Qwen3.5-9B) is the one to use" ;;
    16:laguna)  why="Laguna needs a Mac with 36 GB or more; its smallest build doesn't fit in this Mac's GPU memory" ;;
    36:fast)
      repo=unsloth/Qwen3.6-35B-A3B-UD-MLX-4bit; rev=6700c3e5bdeb050a379c8d2a4133f43f3647f20f
      base=Qwen3.6-35B-A3B-UD-MLX-4bit; base_alias=qwen3.6-35b-a3b; gb=22
      text_ctx=131072; vision_ctx=106496; measured=yes ;;
    36:quality)
      repo=Jundot/Qwen3.8-27B-oQ4e-mtp; rev=04dc5509edd8670fc78cc8c2f74bf9b77b1f2acc
      base=Qwen3.8-27B-oQ4e-mtp; base_alias=qwen3.8-27b; gb=17
      text_ctx=94208; vision_ctx=81920; row_out=20000; caps="-mid_conv_system"; measured=yes ;;
    36:laguna)
      repo=mlx-coders/Laguna-XS-2.1-oQ4e; rev=2cdec8e0a0e3ce1562c92767c394bb952835ee11
      base=Laguna-XS-2.1-oQ4e; base_alias=laguna-xs-2.1; gb=20
      text_ctx=114688; caps="-mid_conv_system"; measured=yes ;;
    96:fast|128:fast)
      repo=Jundot/Qwen3.6-35B-A3B-oQ6-mtp; rev=276df7cc7b6face3d66d635bb841248c51ec3e8d
      base=Qwen3.6-35B-A3B-oQ6-mtp; base_alias=qwen3.6-35b-a3b-oq6; gb=31
      text_ctx=262144; vision_ctx=262144; caps="-mid_conv_system"
      if [ "$class" = 96 ]; then measured=yes; fi ;;
    96:quality|128:quality)
      repo=Jundot/Qwen3.8-27B-oQ6e-mtp; rev=f7ec1f012451c7a76e775e2fdefdd5f0a51f11f7
      base=Qwen3.8-27B-oQ6e-mtp; base_alias=qwen3.8-27b-oq6; gb=24
      text_ctx=131072; vision_ctx=131072; row_out=20000; caps="-mid_conv_system"
      if [ "$class" = 96 ]; then measured=yes; fi ;;
    96:laguna|128:laguna)
      repo=mlx-community/Laguna-S-2.1-oQ4e-fast; rev=871f699b0e8852ee2ab74fb1e67767bdcc6358ee
      base=Laguna-S-2.1-oQ4e-fast; base_alias=laguna-s-2.1; gb=64
      text_ctx=131072; caps="-mid_conv_system"
      if [ "$class" = 96 ]; then measured=yes; else text_ctx=196608; fi ;;
  esac
}

# A window measured on this Mac by install-claude-local.sh --memory-test.
saved_window() {  # saved_window <alias>
  [ -r "$WINDOWS_FILE" ] || return 0
  awk -F= -v a="$1" '{ sub(/#.*/, ""); gsub(/[[:space:]]/, "") }
    $1 == a && $2 ~ /^[0-9]+$/ { w = $2 } END { if (w) print w }' "$WINDOWS_FILE"
}

# profile_row <profile> <vision>: the catalog entry plus, for that vision
# setting, dir, alias and row_ctx (and ctx_src, where the window comes from).
# dir is empty when the combination isn't available; why says why.
profile_row() {
  catalog "$1"
  dir="" alias="" row_ctx=0 ctx_src=""
  [ -n "$base" ] || return 0
  if [ "$2" = "on" ]; then
    if [ -z "$vision_ctx" ]; then
      why="$(label "$1") has no image input"
      return 0
    fi
    dir="$base-vision"; alias="$base_alias-vision"; row_ctx=$vision_ctx
  else
    dir=$base; alias=$base_alias; row_ctx=$text_ctx
  fi
  local w
  w=$(saved_window "$alias")
  if [ -n "$w" ]; then
    row_ctx=$w; ctx_src="set for this Mac in $WINDOWS_FILE"
  elif [ "$measured" = "yes" ]; then
    ctx_src="measured on a $class GB Mac"
  else
    ctx_src="estimate; measure it with install-claude-local.sh --memory-test"
  fi
}

label() {
  case "$1" in
    fast) echo "the fast model ($base_alias)" ;;
    quality) echo "the quality model ($base_alias)" ;;
    laguna) echo "Laguna ($base_alias)" ;;
  esac
}
installed() { [ -f "$OMLX_HOME/models/$1/config.json" ]; }

# Why the model for the current row isn't usable, as a hint for the user.
missing_hint() {
  case "$dir" in
    *-vision) if installed "$base"; then
                echo "its vision variant (~/.omlx/models/$dir) is missing; re-run install-claude-local.sh to create it"
                return
              fi ;;
  esac
  case "$profile" in
    fast) echo "the fast model ($base) is not installed; run install-claude-local.sh" ;;
    *) echo "the $profile model ($base) is not installed; run install-claude-local.sh --with-$profile" ;;
  esac
}

if [ "$cmd" = "catalog" ]; then
  # For install-claude-local.sh: this Mac's roles, one tab-separated line each:
  # profile repo rev base alias gb text_ctx vision_ctx out default why
  for p in fast quality laguna; do
    catalog "$p"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$p" "${repo:--}" "${rev:--}" "${base:--}" \
      "${base_alias:--}" "$gb" "$text_ctx" "${vision_ctx:--}" "$row_out" \
      "$([ "$p" = "$class_default" ] && echo yes || echo no)" "${why:--}"
  done
  exit 0
fi

# --- Resolve model and vision ------------------------------------------------
saved_profile=""
saved_vision=""
if [ -r "$DEFAULTS_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}              # drop comments
    line=${line//[[:space:]]/}    # drop all whitespace, including CR
    case "$line" in
      "") ;;
      profile=fast|profile=quality|profile=laguna) saved_profile=${line#*=} ;;
      vision=on|vision=off) saved_vision=${line#*=} ;;
      *) warn "ignoring '$line' in $DEFAULTS_FILE (expected profile=fast|quality|laguna or vision=on|off)" ;;
    esac
  done < "$DEFAULTS_FILE"
fi

env_profile="${CLAUDE_LOCAL_PROFILE:-}"
case "$env_profile" in ""|fast|quality|laguna) ;; *) die "CLAUDE_LOCAL_PROFILE must be fast, quality or laguna" ;; esac
case "${CLAUDE_LOCAL_VISION:-}" in
  "") env_vision="" ;;
  on|1|yes|true) env_vision=on ;;
  off|0|no|false) env_vision=off ;;
  *) die "CLAUDE_LOCAL_VISION must be on or off" ;;
esac
case "${CLAUDE_LOCAL_LEAN:-}" in
  "") if [ "$class" = 16 ]; then lean=on; lean_src="built-in for 16 GB Macs"; else lean=off; lean_src="built-in"; fi ;;
  on|1|yes|true) lean=on; lean_src="CLAUDE_LOCAL_LEAN" ;;
  off|0|no|false) lean=off; lean_src="CLAUDE_LOCAL_LEAN" ;;
  *) die "CLAUDE_LOCAL_LEAN must be on or off" ;;
esac

# Remember where each choice came from, for --local-status.
if [ -n "$opt_profile" ]; then profile=$opt_profile; profile_src="option"
elif [ -n "$env_profile" ]; then profile=$env_profile; profile_src="CLAUDE_LOCAL_PROFILE"
elif [ -n "$saved_profile" ]; then profile=$saved_profile; profile_src="saved default"
else profile=$class_default; profile_src="built-in for this Mac"; fi
if [ -n "$opt_vision" ]; then vision=$opt_vision; vision_src="option"
elif [ -n "$env_vision" ]; then vision=$env_vision; vision_src="CLAUDE_LOCAL_VISION"
elif [ -n "$saved_vision" ]; then vision=$saved_vision; vision_src="saved default"
else vision=off; vision_src="built-in"; fi

if [ "$cmd" = "set-default" ]; then
  [ -n "$opt_profile$opt_vision" ] || die "give --local-fast/--local-quality/--local-laguna and/or --local-vision/--local-no-vision to save"
  # Save only what the options say; keep the other saved value. Environment
  # variables are never saved.
  new_profile="${opt_profile:-${saved_profile:-$class_default}}"
  new_vision="${opt_vision:-${saved_vision:-off}}"
  profile=$new_profile
  profile_row "$new_profile" "$new_vision"
  [ -n "$dir" ] || die "can't save that default: $why"
  installed "$dir" || die "can't save that default: $(missing_hint)"
  mkdir -p "$(dirname "$DEFAULTS_FILE")"
  tmp=$(mktemp "$DEFAULTS_FILE.XXXXXX")
  {
    echo "# claude-local saved defaults (claude-local --local-set-default); edit or delete freely"
    echo "profile=$new_profile"
    echo "vision=$new_vision"
  } > "$tmp"
  mv "$tmp" "$DEFAULTS_FILE"
  echo "claude-local: saved default: $new_profile, vision $new_vision ($DEFAULTS_FILE)"
  exit 0
fi

profile_row "$profile" "$vision"
# A model without image input: an explicit --local-vision is an error; a
# saved or environment vision=on is set aside for this model.
if [ -z "$dir" ] && [ -n "$base" ] && [ "$vision" = "on" ]; then
  [ "$vision_src" != "option" ] || [ "$cmd" = "status" ] || [ "$cmd" = "stop" ] \
    || die "$why; drop --local-vision, or pick a model that has it"
  if [ "$vision_src" != "option" ]; then
    [ "$cmd" = "status" ] || warn "$why, so vision is off for this session (vision on came from the $vision_src)"
    vision=off; vision_src="$vision_src, but $(label "$profile") has no image input"
    profile_row "$profile" off
  fi
fi
if [ -z "$base" ] && [ "$cmd" != "status" ] && [ "$cmd" != "stop" ]; then
  die "no $profile model on this Mac: $why"
fi

backend="${CLAUDE_LOCAL_BACKEND:-omlx}"
case "$backend" in
  omlx)
    port="${CLAUDE_LOCAL_PORT:-8765}"
    token="local"
    ;;
  ollama)
    [ "$profile:$vision" = "fast:off" ] || [ -n "${CLAUDE_LOCAL_MODEL:-}" ] \
      || die "the Ollama backend only has the fast model without vision; set CLAUDE_LOCAL_MODEL"
    port="${CLAUDE_LOCAL_PORT:-11434}"
    alias="qwen3.6:35b-a3b-coding-nvfp4"
    token="ollama"
    caps=""
    ;;
  *)
    echo "claude-local: unknown CLAUDE_LOCAL_BACKEND '$backend' (use omlx or ollama)" >&2
    exit 2
    ;;
esac
model="${CLAUDE_LOCAL_MODEL:-$alias}"
ctx="${CLAUDE_LOCAL_CTX:-$row_ctx}"
[ -z "${CLAUDE_LOCAL_CTX:-}" ] || ctx_src="CLAUDE_LOCAL_CTX"
max_out="${CLAUDE_LOCAL_MAX_OUT:-$row_out}"
base_url="http://127.0.0.1:$port"
# One pid file per port, so a test server on another port can't clobber it.
if [ "$port" = "8765" ]; then OMLX_PIDFILE="$OMLX_HOME/claude-local-server.pid"
else OMLX_PIDFILE="$OMLX_HOME/claude-local-server-$port.pid"; fi

# --- Server helpers ----------------------------------------------------------
# True when the backend answers and lists $model.
server_has_model() {
  curl -fsS -m 3 -H "Authorization: Bearer $token" "$base_url/v1/models" 2>/dev/null \
    | /usr/bin/jq -e --arg m "$model" 'any(.data[]?; .id == $m)' >/dev/null 2>&1
}

port_listener_pid() {
  lsof -nP -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null | head -1 || true
}

is_omlx_pid() {
  case "$(ps -o command= -p "$1" 2>/dev/null)" in *omlx*) return 0 ;; *) return 1 ;; esac
}

# Prints "<alias> <seconds since last use>" for each model oMLX has loaded.
loaded_models() {
  curl -fsS -m 3 -H "Authorization: Bearer $token" "$base_url/v1/models/status" 2>/dev/null \
    | /usr/bin/jq -r --argjson now "$(date +%s)" \
        '.models[]? | select(.loaded) | "\(.model_alias // .id) \(if .last_access then ($now - .last_access | floor) else -1 end)"' \
        2>/dev/null || true
}

# On the smaller Macs a second big process matters: OrbStack's VM can hold
# ~13 GB, and other model servers compete for the same GPU memory.
memory_warnings() {
  if [ "$class" = 16 ] || [ "$class" = 36 ]; then
    if command -v orbctl >/dev/null 2>&1 && [ "$(orbctl status 2>/dev/null)" = "Running" ]; then
      warn "OrbStack is running (its VM can hold many GB). Stop it with 'orbctl stop' for best performance."
    fi
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

# Requests the server is working on or has queued ("?" if it can't say).
requests_in_flight() {
  curl -fsS -m 3 -H "Authorization: Bearer $token" "$base_url/api/status" 2>/dev/null \
    | /usr/bin/jq -r '(.active_requests // 0) + (.waiting_requests // 0)' 2>/dev/null || echo "?"
}

# Switching models evicts the other one unless both fit in memory (only the
# Qwen pair on the Studios). last_access is set when a request starts, so a
# long generation can look idle; the in-flight count covers that.
swap_warning() {
  [ "$backend" = "omlx" ] || return 0
  local other idle busy
  busy=$(requests_in_flight)
  while read -r other idle; do
    [ -n "$other" ] && [ "$other" != "$model" ] || continue
    if [ "$busy" != "0" ] && [ "$busy" != "?" ]; then
      warn "$other is serving a request right now, probably for another session; this launch will wait for it, and may swap it out for $model."
    elif [ "$idle" -ge 0 ] && [ "$idle" -lt 600 ]; then
      warn "$other was used ${idle}s ago, probably by another session; this launch may swap it out for $model."
    fi
  done <<EOF
$(loaded_models)
EOF
  return 0
}

# Claude Code subcommands (mcp, doctor, update, ...) take no session flags
# and need no model.
is_subcommand() {
  case "${1:-}" in
    agents|attach|auth|auto-mode|doctor|gateway|import|install|logs|mcp|plugin|plugins|project|respawn|rm|setup-token|stop|kill|ultrareview|update|upgrade) return 0 ;;
  esac
  return 1
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
  is_omlx_pid "$pid" || die "pid $pid on port $port is not oMLX; not stopping it"
  kill -TERM "$pid" 2>/dev/null || true
  local i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 20 ]; do sleep 1; i=$((i + 1)); done
  # The server can linger holding GPU memory (oMLX #3431); force it if needed.
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
  rm -f "$OMLX_PIDFILE"
  echo "claude-local: oMLX stopped"
}

# Ask the server to load the model now, so the first Claude Code turn
# doesn't also pay the load time.
warm_model() {
  curl -fsS -m 600 -H "Authorization: Bearer $token" -H "content-type: application/json" \
    -H "anthropic-version: 2023-06-01" "$base_url/v1/messages" \
    -d "{\"model\":\"$model\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"thinking\":{\"type\":\"disabled\"}}" \
    >/dev/null
}

# Make sure the requested model exists, and the server is up and lists it.
ensure_server() {
  if [ "$backend" = "omlx" ] && [ -z "${CLAUDE_LOCAL_MODEL:-}" ] && ! installed "$dir"; then
    die "$(missing_hint)"
  fi
  server_has_model && return 0
  [ "$backend" = "omlx" ] || die "Ollama is not serving '$model' at $base_url (is the Ollama app running?)"
  local pid
  pid=$(port_listener_pid)
  if [ -n "$pid" ]; then
    is_omlx_pid "$pid" \
      && die "oMLX is running but doesn't list '$model'. Run 'claude-local --local-stop' so the next launch rescans its models."
    die "port $port is in use by pid $pid, which isn't oMLX. Check it with: lsof -nP -iTCP:$port"
  fi
  start_omlx
}

show_status() {
  local mark reserve p v
  # Claude Code compacts at W - min(max output, 20000) - 13000 and refuses
  # to send past W - min(max output, 20000) - 3000.
  reserve=$(( max_out < 20000 ? max_out : 20000 ))
  echo "model:      $profile ($profile_src) -> ${model:-none}"
  echo "vision:     $vision ($vision_src)"
  if [ -n "$dir" ] || [ -n "${CLAUDE_LOCAL_MODEL:-}" ]; then
    echo "context:    $ctx (auto-compact ~$((ctx - reserve - 13000)), hard limit ~$((ctx - reserve - 3000))); max output $max_out"
    echo "            window: ${ctx_src:-built-in}"
  elif [ -z "$base" ]; then
    echo "context:    - (no $profile model on this Mac: $why)"
  else
    echo "context:    - ($why)"
  fi
  if [ "$vision" = "off" ]; then
    echo "images:     off; reading image files is refused, and pasted images aren't seen by the model"
  fi
  if [ "$lean" = "on" ]; then
    echo "tools:      lean ($lean_src): Read, Edit, Write, Bash, Grep, Glob; no slash commands"
  fi
  echo "machine:    $class GB class ($class_src)"
  echo "backend:    $backend $base_url"
  if [ -n "$model" ] && server_has_model; then
    local loaded
    loaded=$(loaded_models | awk '{ printf "%s%s (idle %ss)", sep, $1, $2; sep = ", " }')
    echo "server:     up; loaded: ${loaded:-none}"
  else
    echo "server:     down, or '${model:-}' not listed"
  fi
  echo "defaults:   $DEFAULTS_FILE$([ -r "$DEFAULTS_FILE" ] || echo ' (none saved)')"
  echo "claude:     $CLAUDE_BIN"
  echo "omlx:       $OMLX_CLI"
  echo "models on this Mac:"
  for p in fast quality laguna; do
    for v in off on; do
      profile_row "$p" "$v"
      if [ -z "$base" ]; then
        [ "$v" = "off" ] && printf '            %-8s %s\n' "$p" "not on this Mac: $why"
        continue
      fi
      if [ -z "$dir" ]; then
        mark="no image input"
      elif installed "$dir"; then
        case "$ctx_src" in
          "set for this Mac"*) mark="installed      ctx $row_ctx (this Mac)" ;;
          "measured"*) mark="installed      ctx $row_ctx (measured)" ;;
          *) mark="installed      ctx $row_ctx (estimate)" ;;
        esac
      else
        mark="not installed"
      fi
      printf '            %-8s vision %-4s %-27s %s\n' "$p" "$v" "$alias" "$mark"
    done
  done
  profile_row "$profile" "$vision"
}

case "$cmd" in
  status)
    show_status
    memory_warnings
    exit 0
    ;;
  stop)
    [ "$backend" = "omlx" ] || die "--local-stop only manages oMLX; quit Ollama from its menu-bar app"
    stop_omlx
    exit 0
    ;;
  start)
    memory_warnings
    ensure_server
    swap_warning
    echo "claude-local: loading '$model'..." >&2
    warm_model || die "the model failed to load; see $OMLX_LOG"
    echo "claude-local: ready at $base_url ($profile, vision $vision)"
    exit 0
    ;;
esac

if ! is_subcommand "${1:-}"; then
  memory_warnings
  ensure_server
  swap_warning
  [ -t 2 ] && echo "claude-local: $profile, vision $vision -> $model, context $ctx" >&2
fi

[ -d "$LOCAL_CONFIG_DIR" ] || mkdir -p "$LOCAL_CONFIG_DIR"

# Drop anything that could route or authenticate elsewhere.
unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_PROFILE ANTHROPIC_BETAS \
  ANTHROPIC_SMALL_FAST_MODEL CLAUDE_CODE_SIMPLE CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX \
  CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_MANTLE CLAUDE_CODE_USE_GATEWAY \
  CLAUDE_CODE_USE_ANTHROPIC_AWS CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD \
  CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT \
  CLAUDE_CODE_AUTO_COMPACT_WINDOW CLAUDE_SECURESTORAGE_CONFIG_DIR CLAUDE_CODE_MODEL_CAPABILITIES

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

# Most of these models' chat templates reject system messages after the first
# one, and oMLX then moves them to the front, which breaks the prefix cache.
[ -z "$caps" ] || export CLAUDE_CODE_MODEL_CAPABILITIES="$caps"

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

is_subcommand "${1:-}" && exec "$CLAUDE_BIN" "$@"

# Lean: a smaller tool set cuts Claude Code's prompt from ~16K to ~4.5K
# tokens, which a slow Mac needs minutes to process on every cache miss.
if [ "$lean" = "on" ]; then
  set -- --tools=Read,Edit,Write,Bash,Grep,Glob --disable-slash-commands "$@"
fi

# Without vision the server drops images silently. A hook on the Read tool
# refuses image files with a clear message instead. (Deny rules would also
# hide image files from Glob and Grep.) The reason must not contain a quote.
if [ "$vision" = "off" ]; then
  if [ -n "$vision_ctx" ]; then
    how="Tell the user to relaunch with claude-local --local-vision."
  else
    catalog fast
    if [ -n "$vision_ctx" ]; then
      how="This model has no image input; tell the user to relaunch with claude-local --local-fast --local-vision."
    else
      how="No model on this Mac has image input."
    fi
  fi
  reason="Image input is off in this claude-local session, so image files cannot be viewed. There is no workaround: do not try to decode, OCR or convert images with shell commands or scripts. $how"
  deny=$(/usr/bin/jq -cn --arg r "$reason" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}')
  image_hook="/usr/bin/jq -r '.tool_input.file_path // empty' | /usr/bin/grep -qiE '[.](png|jpe?g|gif|webp)\$' || exit 0
printf '%s\n' '$deny'"
  hook_settings=$(/usr/bin/jq -cn --arg c "$image_hook" \
    '{hooks: {PreToolUse: [{matcher: "Read", hooks: [{type: "command", command: $c}]}]}}')
  set -- "--settings=$hook_settings" "$@"
fi

# WebSearch is an Anthropic server-side tool; LSP schema changes break the
# prefix cache.
exec "$CLAUDE_BIN" --strict-mcp-config --exclude-dynamic-system-prompt-sections \
  --disallowedTools=WebSearch,LSP "$@"
CLAUDE_LOCAL_SCRIPT
chmod 755 "$NEW_WRAPPER"
bash -n "$NEW_WRAPPER" || die "internal error: the embedded wrapper has a syntax error"
CATALOG=$("$NEW_WRAPPER" --local-catalog) || die "internal error: the embedded wrapper has no catalog"

# cat_field <profile> <field>: this Mac's catalog entry for a role ('-' = none).
cat_field() {
  local col
  case "$2" in
    repo) col=2 ;; rev) col=3 ;; base) col=4 ;; alias) col=5 ;; gb) col=6 ;;
    text_ctx) col=7 ;; vision_ctx) col=8 ;; out) col=9 ;; default) col=10 ;; why) col=11 ;;
  esac
  printf '%s\n' "$CATALOG" | awk -F'\t' -v p="$1" -v c="$col" '$1 == p { print $c }'
}
available() { [ "$(cat_field "$1" base)" != "-" ]; }
has_vision() { [ "$(cat_field "$1" vision_ctx)" != "-" ]; }

# Which roles to install: fast always, this Mac's default role, anything
# asked for, and anything already installed (kept up to date).
default_profile=$(printf '%s\n' "$CATALOG" | awk -F'\t' '$10 == "yes" { print $1 }')
want=""
for p in fast quality laguna; do
  asked=0
  case "$p" in
    quality) asked=$with_quality ;;
    laguna) asked=$with_laguna ;;
  esac
  if ! available "$p"; then
    [ "$asked" -eq 0 ] || warn "--with-$p: $(cat_field "$p" why)"
    continue
  fi
  if [ "$p" = "fast" ] || [ "$p" = "$default_profile" ] || [ "$asked" -eq 1 ] || installed "$(cat_field "$p" base)"; then
    want="$want $p"
  fi
done

# Measured context windows for this Mac (install-claude-local.sh --memory-test).
set_window() {  # set_window <alias> <window>
  mkdir -p "$(dirname "$WINDOWS_FILE")"
  local tmp
  tmp=$(mktemp "$WINDOWS_FILE.XXXXXX")
  { [ -f "$WINDOWS_FILE" ] && grep -v "^$1=" "$WINDOWS_FILE" || echo "# context windows measured on this Mac by install-claude-local.sh --memory-test"; } > "$tmp"
  echo "$1=$2" >> "$tmp"
  mv "$tmp" "$WINDOWS_FILE"
}
clear_window() {  # clear_window <alias>
  [ -f "$WINDOWS_FILE" ] && grep -q "^$1=" "$WINDOWS_FILE" || return 0
  local tmp
  tmp=$(mktemp "$WINDOWS_FILE.XXXXXX")
  grep -v "^$1=" "$WINDOWS_FILE" > "$tmp" || true
  mv "$tmp" "$WINDOWS_FILE"
}

# ---------------------------------------------------------------------------
step "1/8 Checking this Mac"
[ "$(uname -m)" = "arm64" ] || die "Apple Silicon is required."
macos_ver=$(sw_vers -productVersion)
macos_major=${macos_ver%%.*}
[ "$macos_major" -ge 15 ] || die "macOS 15 or later is required (found $macos_ver)."
ram_gib=$(( $(sysctl -n hw.memsize) / 1073741824 ))
info "$(sysctl -n machdep.cpu.brand_string), $ram_gib GB memory, macOS $macos_ver"
if [ "$ram_gib" -lt 16 ]; then
  [ "$force" -eq 1 ] || die "This setup needs 16 GB of memory or more (found $ram_gib GB). Use --force to try anyway."
  warn "only $ram_gib GB of memory; continuing because of --force"
fi
class=$("$NEW_WRAPPER" --local-status 2>/dev/null | awk '/^machine:/ { print $2 }')
info "memory class: $class GB; models to install:$want (default: $default_profile)"
for p in fast quality laguna; do
  available "$p" || info "  $p: not on this Mac ($(cat_field "$p" why))"
done
[ -x "$JQ" ] || die "/usr/bin/jq not found (it ships with macOS 15 and later)."

CLAUDE_BIN="$HOME/.local/bin/claude"
[ -x "$CLAUDE_BIN" ] || CLAUDE_BIN="$(command -v claude || true)"
[ -n "$CLAUDE_BIN" ] || die "Claude Code not found. Install it first (https://code.claude.com/docs) and log in."
info "Claude Code: $CLAUDE_BIN ($("$CLAUDE_BIN" --version 2>/dev/null | head -1))"

# Disk: each model still to download, plus room for oMLX and some slack. The
# SSD prompt cache grows later, up to its cap (step 5).
case "$class" in
  16) ssd_cache="20GB" ;;
  36) ssd_cache="50GB" ;;
  *) ssd_cache="300GB" ;;
esac
need_gb=5
for p in $want; do
  b=$(cat_field "$p" base)
  have=$( { du -sgL "$OMLX_HOME/models/$b" "$OMLX_HOME/downloads/$b" 2>/dev/null || true; } \
    | awk '{ s += $1 } END { print s + 0 }')
  left=$(( $(cat_field "$p" gb) - have ))
  [ "$left" -le 0 ] || need_gb=$(( need_gb + left ))
done
free_gb=$(df -g "$HOME" | awk 'NR == 2 {print $4}')
[ "$free_gb" -ge "$need_gb" ] || die "Need about $need_gb GB of free disk space; only $free_gb GB free."
info "disk: $free_gb GB free, about $need_gb GB needed now; the prompt cache can grow to $ssd_cache"

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
  settings_sha > "$BASELINE/sha.txt"
  "$CLAUDE_BIN" auth status > "$BASELINE/auth.txt" 2>/dev/null || true
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
  trap 'hdiutil detach "$mnt" >/dev/null 2>&1 || true; rm -f "$NEW_WRAPPER"' EXIT
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
  trap 'rm -f "$NEW_WRAPPER"' EXIT
  info "installed oMLX $("$OMLX_CLI" --version) at $APP"
  info "(don't open it from Finder; claude-local runs its server headless)"
fi

# ---------------------------------------------------------------------------
step "3/8 Downloading the models (INSTALL.md step 3)"

# download_one <repo> <revision> <folder> <file> <size>: one file, resumable,
# until its size matches Hugging Face's.
download_one() {
  local out="$3/$4" try
  mkdir -p "$(dirname "$out")"
  for try in 1 2 3 4 5; do
    [ "$(stat -f %z "$out" 2>/dev/null || echo 0)" = "$5" ] && return 0
    info "downloading $4 ($(( $5 / 1000000 )) MB), attempt $try"
    curl -fsSL --retry 5 --retry-delay 5 -C - -o "$out" "https://huggingface.co/$1/resolve/$2/$4" || true
  done
}

# download_model <repo> <revision> <folder> [<file> <url> <sha256>]:
# resumable, pinned to a revision, sizes checked against Hugging Face. Four
# files download at once (Hugging Face limits each connection), each file by
# only one worker. New downloads go to ~/.omlx/downloads first and move into
# ~/.omlx/models when complete, so the server never sees a half-finished
# model. The optional file is taken from <url> (checked against <sha256>)
# instead of the repo. Python files are skipped: they are model code for other
# runtimes, which oMLX never runs (and some web proxies block).
download_model() {
  local repo="$1" rev="$2" name="$3" dest="$OMLX_HOME/models/$3" work f sz k failed=0
  local swap="${4:-}" swap_url="${5:-}" swap_sha="${6:-}"
  if [ -d "$dest" ]; then work="$dest"; else work="$OMLX_HOME/downloads/$name"; fi
  mkdir -p "$work"
  info "$repo @ ${rev:0:8} -> $dest"
  curl -fsSL "https://huggingface.co/api/models/$repo/tree/$rev?recursive=true" \
    | "$JQ" -r '.[] | select(.type == "file" and .path != ".gitattributes" and (.path | endswith(".py") | not))
        | "\(.path) \(.lfs.size // .size)"' \
    | grep -v "^$swap " > "$work/.filelist" || true
  [ -s "$work/.filelist" ] || die "Could not list $repo on Hugging Face."
  for k in 0 1 2 3; do
    awk -v k="$k" 'NR % 4 == k' "$work/.filelist" | while read -r f sz; do
      download_one "$repo" "$rev" "$work" "$f" "$sz"
    done &
  done
  wait
  while read -r f sz; do
    if [ "$(stat -f %z "$work/$f" 2>/dev/null || echo 0)" = "$sz" ]; then
      info "OK   $f"
    else
      warn "FAIL $f"
      failed=1
    fi
  done < "$work/.filelist"
  [ "$failed" -eq 0 ] || die "Some files of $repo did not download. Re-run to resume."
  if [ -n "$swap" ]; then
    if [ "$(shasum -a 256 "$work/$swap" 2>/dev/null | awk '{ print $1 }')" = "$swap_sha" ]; then
      info "OK   $swap (replacement)"
    else
      curl -fsSL -o "$work/$swap.new" "$swap_url" || die "Could not download $swap_url."
      [ "$(shasum -a 256 "$work/$swap.new" | awk '{ print $1 }')" = "$swap_sha" ] \
        || die "Checksum mismatch for $swap_url."
      mv "$work/$swap.new" "$work/$swap"
      models_changed=1
      info "OK   $swap (replaced from $swap_url)"
    fi
  fi
  if [ "$work" != "$dest" ]; then
    mkdir -p "$OMLX_HOME/models"
    mv "$work" "$dest"
    models_changed=1
  fi
}

models_changed=0
for p in $want; do
  b=$(cat_field "$p" base)
  if [ "$b" = "Laguna-XS-2.1-oQ4e" ]; then
    download_model "$(cat_field "$p" repo)" "$(cat_field "$p" rev)" "$b" \
      chat_template.jinja "$XS_TEMPLATE_URL" "$XS_TEMPLATE_SHA"
  else
    download_model "$(cat_field "$p" repo)" "$(cat_field "$p" rev)" "$b"
  fi
done
for p in quality laguna; do
  case " $want " in *" $p "*) ;; *) available "$p" && info "$p model not requested; add --with-$p to install it" ;; esac
done

# Vision variants are symlinks to the same weights under another model id,
# which oMLX serves with its vision engine.
for p in $want; do
  has_vision "$p" || continue
  name=$(cat_field "$p" base)
  link="$OMLX_HOME/models/$name-vision"
  if [ "$(readlink "$link" 2>/dev/null || true)" = "$name" ]; then
    info "vision variant: $name-vision is in place"
  elif [ -L "$link" ] || [ ! -e "$link" ]; then
    ln -sfn "$name" "$link"
    models_changed=1
    info "vision variant: $name-vision -> $name"
  else
    warn "$link exists and is not a symlink; leaving it alone"
  fi
done

# ---------------------------------------------------------------------------
step "4/8 Sizing for this Mac's GPU memory budget (INSTALL.md step 7)"
budget=$(omlx_py -c "import mlx.core as mx; print(round(mx.device_info()['max_recommended_working_set_size'] / 2**30, 1))") \
  || die "Could not read the GPU memory budget with oMLX's bundled Python."
info "GPU budget: $budget GiB"
case "$class" in
  16) expect=10 ;;
  36) expect=27 ;;
  96) expect=70 ;;
  *) expect=90 ;;
esac
if awk -v b="$budget" -v e="$expect" 'BEGIN { exit !(b < e) }'; then
  warn "a $class GB class Mac usually has at least $expect GiB; the built-in context windows may not fit. Run with --memory-test to measure them."
fi
tier="aggressive"
info "memory guard tier: $tier (context windows per model: claude-local --local-status)"
# macOS 15 gives a 16 GB Mac about 1.2 GiB less GPU memory than macOS 26.
if [ "$class" = 16 ] && [ "$macos_major" -lt 26 ]; then
  a=$(cat_field fast alias)
  if [ -z "$(awk -F= -v a="$a" '$1 == a' "$WINDOWS_FILE" 2>/dev/null)" ]; then
    set_window "$a" 49152
    info "macOS $macos_ver: using a 49152-token window for $a (recorded in $WINDOWS_FILE)"
  fi
fi

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
   && ! "$JQ" -e --arg k "$(cat_field fast base)" --arg a "$(cat_field fast alias)" '.models[$k].model_alias == $a' "$models" >/dev/null 2>&1; then
  cp "$models" "$models.pre-claude-local"
  info "saved your previous model_settings.json as model_settings.json.pre-claude-local"
fi
[ -f "$settings" ] || echo '{"version": "1.0"}' > "$settings"
[ -f "$models" ] || echo '{"version": 1, "models": {}}' > "$models"

tmp=$(mktemp)
"$JQ" --argjson port "$PORT" --arg tier "$tier" --arg ssd "$ssd_cache" '
    .version //= "1.0"
  | .server.host = "127.0.0.1" | .server.port = $port | .server.log_level //= "info"
  | .scheduler.max_concurrent_requests = 1
  | .cache.enabled = true | .cache.ssd_cache_max_size = $ssd | .cache.hot_cache_max_size = "0"
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

# Settings for every model and vision variant; entries for models that aren't
# installed are harmless. Values already in an entry win, so your own edits
# (such as reasoning_effort) survive re-runs; only model_alias and
# model_type_override are always reset, because claude-local depends on them.
model_entries=$(cat <<'MODEL_ENTRIES'
{
  "Qwen3.5-9B-oQ4e-fp16-text-only": {
    "model_alias": "qwen3.5-9b",
    "display_name": "Qwen3.5-9B (oQ4e fp16, text only)",
    "max_context_window": 81920,
    "max_tokens": 16384,
    "temperature": 0.6,
    "top_p": 0.95,
    "top_k": 20,
    "min_p": 0.0,
    "presence_penalty": 0.0,
    "repetition_penalty": 1.0,
    "enable_thinking": true,
    "ttl_seconds": 1800,
    "is_default": false,
    "model_type_override": "llm"
  },
  "Qwen3.6-35B-A3B-UD-MLX-4bit": {
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
  },
  "Qwen3.6-35B-A3B-UD-MLX-4bit-vision": {
    "model_alias": "qwen3.6-35b-a3b-vision",
    "display_name": "Qwen3.6-35B-A3B (Unsloth UD-MLX-4bit, vision)",
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
    "is_default": false,
    "model_type_override": "vlm"
  },
  "Qwen3.8-27B-oQ4e-mtp": {
    "model_alias": "qwen3.8-27b",
    "display_name": "Qwen3.8-27B (oMLX oQ4e-mtp)",
    "max_context_window": 163840,
    "max_tokens": 32768,
    "temperature": 1.0,
    "top_p": 0.95,
    "top_k": 20,
    "min_p": 0.0,
    "presence_penalty": 0.0,
    "repetition_penalty": 1.0,
    "enable_thinking": true,
    "preserve_thinking": true,
    "chat_template_kwargs": {
      "reasoning_effort": "medium"
    },
    "mtp_enabled": true,
    "ttl_seconds": 1800,
    "is_default": false,
    "model_type_override": "llm"
  },
  "Qwen3.8-27B-oQ4e-mtp-vision": {
    "model_alias": "qwen3.8-27b-vision",
    "display_name": "Qwen3.8-27B (oMLX oQ4e-mtp, vision)",
    "max_context_window": 163840,
    "max_tokens": 32768,
    "temperature": 1.0,
    "top_p": 0.95,
    "top_k": 20,
    "min_p": 0.0,
    "presence_penalty": 0.0,
    "repetition_penalty": 1.0,
    "enable_thinking": true,
    "preserve_thinking": true,
    "chat_template_kwargs": {
      "reasoning_effort": "medium"
    },
    "mtp_enabled": false,
    "ttl_seconds": 1800,
    "is_default": false,
    "model_type_override": "vlm"
  },
  "Laguna-XS-2.1-oQ4e": {
    "model_alias": "laguna-xs-2.1",
    "display_name": "Laguna XS 2.1 (oQ4e)",
    "max_context_window": 163840,
    "max_tokens": 32768,
    "temperature": 1.0,
    "top_p": 1.0,
    "top_k": 20,
    "min_p": 0.0,
    "presence_penalty": 0.0,
    "repetition_penalty": 1.0,
    "enable_thinking": true,
    "preserve_thinking": true,
    "ttl_seconds": 1800,
    "is_default": false,
    "model_type_override": "llm"
  },
  "Qwen3.6-35B-A3B-oQ6-mtp": {
    "model_alias": "qwen3.6-35b-a3b-oq6",
    "display_name": "Qwen3.6-35B-A3B (oMLX oQ6-mtp)",
    "max_context_window": 262144,
    "max_tokens": 32768,
    "temperature": 0.6,
    "top_p": 0.95,
    "top_k": 20,
    "min_p": 0.0,
    "presence_penalty": 0.0,
    "repetition_penalty": 1.0,
    "enable_thinking": true,
    "preserve_thinking": true,
    "mtp_enabled": true,
    "ttl_seconds": 1800,
    "is_default": false,
    "model_type_override": "llm"
  },
  "Qwen3.6-35B-A3B-oQ6-mtp-vision": {
    "model_alias": "qwen3.6-35b-a3b-oq6-vision",
    "display_name": "Qwen3.6-35B-A3B (oMLX oQ6-mtp, vision)",
    "max_context_window": 262144,
    "max_tokens": 32768,
    "temperature": 0.6,
    "top_p": 0.95,
    "top_k": 20,
    "min_p": 0.0,
    "presence_penalty": 0.0,
    "repetition_penalty": 1.0,
    "enable_thinking": true,
    "preserve_thinking": true,
    "mtp_enabled": false,
    "ttl_seconds": 1800,
    "is_default": false,
    "model_type_override": "vlm"
  },
  "Qwen3.8-27B-oQ6e-mtp": {
    "model_alias": "qwen3.8-27b-oq6",
    "display_name": "Qwen3.8-27B (oMLX oQ6e-mtp)",
    "max_context_window": 163840,
    "max_tokens": 32768,
    "temperature": 1.0,
    "top_p": 0.95,
    "top_k": 20,
    "min_p": 0.0,
    "presence_penalty": 0.0,
    "repetition_penalty": 1.0,
    "enable_thinking": true,
    "preserve_thinking": true,
    "chat_template_kwargs": {
      "reasoning_effort": "medium"
    },
    "mtp_enabled": true,
    "ttl_seconds": 1800,
    "is_default": false,
    "model_type_override": "llm"
  },
  "Qwen3.8-27B-oQ6e-mtp-vision": {
    "model_alias": "qwen3.8-27b-oq6-vision",
    "display_name": "Qwen3.8-27B (oMLX oQ6e-mtp, vision)",
    "max_context_window": 163840,
    "max_tokens": 32768,
    "temperature": 1.0,
    "top_p": 0.95,
    "top_k": 20,
    "min_p": 0.0,
    "presence_penalty": 0.0,
    "repetition_penalty": 1.0,
    "enable_thinking": true,
    "preserve_thinking": true,
    "chat_template_kwargs": {
      "reasoning_effort": "medium"
    },
    "mtp_enabled": false,
    "ttl_seconds": 1800,
    "is_default": false,
    "model_type_override": "vlm"
  },
  "Laguna-S-2.1-oQ4e-fast": {
    "model_alias": "laguna-s-2.1",
    "display_name": "Laguna S 2.1 (oQ4e-fast)",
    "max_context_window": 262144,
    "max_tokens": 32768,
    "temperature": 1.0,
    "top_p": 1.0,
    "top_k": 20,
    "min_p": 0.0,
    "presence_penalty": 0.0,
    "repetition_penalty": 1.0,
    "enable_thinking": true,
    "preserve_thinking": true,
    "ttl_seconds": 1800,
    "is_default": false,
    "model_type_override": "llm"
  }
}
MODEL_ENTRIES
)
tmp=$(mktemp)
"$JQ" --argjson e "$model_entries" '
    .version //= 1
  | .models = (reduce ($e | to_entries[]) as $x ((.models // {});
      .[$x.key] = (($x.value * (.[$x.key] // {})) + ($x.value | {model_alias, model_type_override}))))
  ' "$models" > "$tmp"
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
if [ -f "$WRAPPER" ] && cmp -s "$NEW_WRAPPER" "$WRAPPER"; then
  info "$WRAPPER is up to date"
else
  if [ -f "$WRAPPER" ]; then
    backup="$WRAPPER.bak-$(date +%Y%m%d-%H%M%S)"
    cp -p "$WRAPPER" "$backup"
    info "backed up the previous wrapper to $backup"
  fi
  cp "$NEW_WRAPPER" "$WRAPPER.new"
  mv "$WRAPPER.new" "$WRAPPER"
  info "installed $WRAPPER"
fi
chmod 755 "$WRAPPER"

# ---------------------------------------------------------------------------
if [ "$verify" -eq 0 ]; then
  step "8/8 Skipping checks (--no-verify)"
  if { [ "$config_changed" -eq 1 ] || [ "$models_changed" -eq 1 ]; } \
     && [ -n "$(lsof -nP -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)" ]; then
    warn "oMLX is running with older settings or models; run 'claude-local --local-stop' when no session is using it"
  fi
  info "Start with: claude-local --local-start, then claude-local"
  exit 0
fi

step "8/8 Checking the install (INSTALL.md step 8)"
problems=0
pass() { info "PASS $*"; }
fail() { warn "FAIL $*"; problems=$((problems + 1)); }

if [ "$class" = 16 ] || [ "$class" = 36 ]; then
  if command -v orbctl >/dev/null 2>&1 && [ "$(orbctl status 2>/dev/null)" = "Running" ]; then
    warn "OrbStack is running and can hold many GB; 'orbctl stop' before long sessions"
  fi
fi
# Is the server in use? Checked before this script sends any requests of its
# own. A request in flight, one in the last 10 minutes, or a status that can't
# be read all count as in use.
server_in_use=0
if [ -n "$(lsof -nP -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)" ]; then
  in_flight=$(curl -fsS -m 3 -H "Authorization: Bearer local" "http://127.0.0.1:$PORT/api/status" 2>/dev/null \
    | "$JQ" -r '(.active_requests // 0) + (.waiting_requests // 0)' 2>/dev/null || echo unknown)
  recent=$(curl -fsS -m 3 -H "Authorization: Bearer local" "http://127.0.0.1:$PORT/v1/models/status" 2>/dev/null \
    | "$JQ" -r --argjson now "$(date +%s)" '[.models[]? | select(.last_access != null and ($now - .last_access) < 600)] | length' 2>/dev/null || echo unknown)
  if [ "$in_flight" != "0" ] || [ "$recent" != "0" ]; then server_in_use=1; fi
fi
# A server started before this install doesn't know new models or settings.
if { [ "$config_changed" -eq 1 ] || [ "$models_changed" -eq 1 ]; } \
   && [ -n "$(lsof -nP -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)" ]; then
  if [ "$server_in_use" -eq 0 ] || [ "$restart_server" -eq 1 ]; then
    info "restarting oMLX so it loads the new settings and models"
    "$WRAPPER" --local-stop >/dev/null 2>&1 || true
  else
    warn "oMLX is running with older settings or models and looks busy (a request in flight or in the last 10 minutes, perhaps from an earlier run of this script), so it wasn't restarted. Checks of new models may fail; re-run with --restart-server when it's free."
  fi
fi

info "starting the server and loading the fast model (10 s to a minute the first time)"
if "$WRAPPER" --local-fast --local-no-vision --local-start >/dev/null; then pass "server up at http://127.0.0.1:$PORT with $(cat_field fast alias)"; else fail "server did not start; see ~/.omlx/logs/claude-local-server.log"; fi

# Each installed model: listed by the server, answers correctly, calls tools.
for p in $want; do
  a=$(cat_field "$p" alias)
  installed "$(cat_field "$p" base)" || { fail "$p model $(cat_field "$p" base) is not installed"; continue; }
  if ! curl -fsS -m 5 -H "Authorization: Bearer local" "http://127.0.0.1:$PORT/v1/models" 2>/dev/null \
      | "$JQ" -e --arg a "$a" 'any(.data[]?; .id == $a)' >/dev/null 2>&1; then
    fail "oMLX doesn't list $a yet; re-run with --restart-server so it rescans its models"
    continue
  fi
  [ "$p" = "fast" ] || info "loading the $p model, $a (swaps out the model before it)"
  answer=$(api /v1/messages '{"model":"'"$a"'","max_tokens":8000,"thinking":{"type":"adaptive"},"messages":[{"role":"user","content":"What is 17*23? Answer with just the number."}]}' \
    | "$JQ" -r '[.content[]? | select(.type == "text") | .text] | join("")' 2>/dev/null || true)
  case "$answer" in *391*) pass "$p model ($a) answers correctly (17*23 = 391)" ;; *) fail "$p model ($a): expected 391, got '${answer:0:160}'" ;; esac
  call=$(api /v1/messages '{"model":"'"$a"'","max_tokens":8000,"thinking":{"type":"adaptive"},"tools":[{"name":"Bash","description":"Run a shell command.","input_schema":{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}}],"messages":[{"role":"user","content":"List the files in /tmp using the Bash tool."}]}' \
    | "$JQ" -r '"\(.stop_reason) \([.content[]? | select(.type == "tool_use") | .name] | join(","))"' 2>/dev/null || true)
  case "$call" in "tool_use Bash"*) pass "$p model ($a) calls tools" ;; *) fail "$p model ($a) tool call: got '$call'" ;; esac
done

testdir=$(mktemp -d)
reply=$(cd "$testdir" && "$WRAPPER" -p "Reply with exactly the word OK and nothing else." 2>&1 || true)
case "$reply" in *OK*) pass "claude-local -p works (default model: $default_profile)" ;; *) fail "claude-local -p: $(printf '%s' "$reply" | tail -3)" ;; esac

# Vision: a generated image with a number the model has to read.
if has_vision fast; then
  omlx_py - "$testdir/check.png" <<'PY'
import sys
from PIL import Image, ImageDraw, ImageFont
img = Image.new("RGB", (640, 400), "white")
try:
    font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Bold.ttf", 72)
except OSError:
    font = ImageFont.load_default()
ImageDraw.Draw(img).text((200, 150), "4821", fill="black", font=font)
img.save(sys.argv[1])
PY
  seen=$(printf '{"model":"%s-vision","max_tokens":2000,"thinking":{"type":"adaptive"},"messages":[{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"%s"}},{"type":"text","text":"What number is written in this image? Reply with just the number."}]}]}' \
      "$(cat_field fast alias)" "$(base64 -i "$testdir/check.png" | tr -d '\n')" > "$testdir/vision.json" \
    && api /v1/messages "@$testdir/vision.json" | "$JQ" -r '[.content[]? | select(.type == "text") | .text] | join("")' 2>/dev/null || true)
  case "$seen" in *4821*) pass "vision works (the fast model read 4821 from an image)" ;; *) fail "vision check: expected 4821, got '$seen'" ;; esac
fi
rm -rf "$testdir"

# Memory test: for each installed model and vision setting, one prompt at
# Claude Code's largest size for its window (window - min(max output, 20000)
# - 3000 tokens; vision with an image), on a freshly started server so the
# peak is this prompt's alone. A window that fails is lowered step by step until one passes, and
# the result is recorded for this Mac in $WINDOWS_FILE.
if [ "$memory_test" -eq 1 ]; then
  if [ "$server_in_use" -eq 1 ] && [ "$restart_server" -eq 0 ]; then
    warn "skipping the memory test: the server looked busy before this run (a request in flight or in the last 10 minutes, perhaps from an earlier run of this script); use --restart-server to run it anyway"
  else
    memdir=$(mktemp -d)
    omlx_py - "$memdir/check.png" <<'PY'
import sys
from PIL import Image, ImageDraw, ImageFont
img = Image.new("RGB", (640, 400), "white")
try:
    font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Bold.ttf", 72)
except OSError:
    font = ImageFont.load_default()
ImageDraw.Draw(img).text((200, 150), "4821", fill="black", font=font)
img.save(sys.argv[1])
PY
    if [ "$class" = 16 ]; then floor=49152; else floor=65536; fi
    for p in $want; do
      for v in off on; do
        if [ "$v" = "on" ]; then
          has_vision "$p" || continue
          alias="$(cat_field "$p" alias)-vision"; start_w=$(cat_field "$p" vision_ctx); img="$memdir/check.png"
        else
          alias=$(cat_field "$p" alias); start_w=$(cat_field "$p" text_ctx); img=""
        fi
        if [ "$start_w" -ge 131072 ]; then stepw=16384; else stepw=8192; fi
        out=$(cat_field "$p" out)
        reserve=$(( (out < 20000 ? out : 20000) + 3000 ))
        ratio=""
        w=$start_w
        result_w=""
        while [ "$w" -ge "$floor" ]; do
          info "memory test: $alias at window $w$([ -n "$img" ] && echo ' (with an image)')"
          "$WRAPPER" --local-stop >/dev/null 2>&1 || true
          "$WRAPPER" "--local-$p" "--local-$([ "$v" = on ] && echo vision || echo no-vision)" --local-start >/dev/null 2>&1 \
            || { fail "memory test: $alias did not start"; break; }
          # Characters per token for this model's tokenizer, from a sample.
          if [ -z "$ratio" ]; then
            omlx_py - "$alias" "$memdir/sample.json" <<'PY' || true
import glob, json, os, sys, sysconfig
alias, out = sys.argv[1], sys.argv[2]
text = "SAMPLE\n"
for f in sorted(glob.glob(os.path.join(sysconfig.get_paths()["stdlib"], "*.py"))):
    text += f"\n##### FILE: {os.path.basename(f)}\n" + open(f, encoding="utf-8", errors="replace").read()
    if len(text) >= 60000:
        break
text = text[:60000]
json.dump({"model": alias, "max_tokens": 1, "thinking": {"type": "disabled"},
           "messages": [{"role": "user", "content": text}]}, open(out, "w"))
PY
            tokens=$(api /v1/messages "@$memdir/sample.json" | "$JQ" -r '.usage.input_tokens // empty' 2>/dev/null || true)
            case "$tokens" in
              ""|*[!0-9]*) ratio=3.5; info "  couldn't measure this model's characters per token; assuming $ratio" ;;
              *) ratio=$(awk -v t="$tokens" 'BEGIN { printf "%.3f", 60000 / (t - 30) }'); info "  $ratio characters per token" ;;
            esac
          fi
          expected=$(omlx_py - "$alias" "$(( w - reserve ))" "$ratio" "$img" "$memdir/long.json" <<'PY'
import base64, glob, json, os, sys, sysconfig, time
alias, tokens, ratio, img, out = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), sys.argv[4], sys.argv[5]
target = int(tokens * ratio * 0.98)   # Claude Code's largest prompt at this window
text = f"RUN {time.time()}\n"   # unique start, so no earlier run's cache helps
for f in sorted(glob.glob(os.path.join(sysconfig.get_paths()["stdlib"], "**", "*.py"), recursive=True)):
    text += f"\n##### FILE: {os.path.basename(f)}\n" + open(f, encoding="utf-8", errors="replace").read()
    if len(text) >= target:
        break
text = text[:target]
last = text[text.rindex("##### FILE: ") + 12:].split("\n", 1)[0]
q = "\n\nQuestion: What is the file name in the very last '##### FILE:' header above? Reply with only the file name."
content = [{"type": "text", "text": text + q}]
if img:
    data = base64.b64encode(open(img, "rb").read()).decode()
    content.insert(0, {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": data}})
json.dump({"model": alias, "max_tokens": 200, "thinking": {"type": "disabled"},
           "messages": [{"role": "user", "content": content}]}, open(out, "w"))
print(last)
PY
) || { fail "memory test: $alias: couldn't build the test prompt"; break; }
          start=$(date +%s)
          resp=$(api /v1/messages "@$memdir/long.json" 2>/dev/null || true)
          secs=$(( $(date +%s) - start ))
          result=$(printf '%s' "$resp" | "$JQ" -r '.content[0].text // .error.message // "no response"' 2>/dev/null || echo "no response")
          sent=$(printf '%s' "$resp" | "$JQ" -r '.usage.input_tokens // "?"' 2>/dev/null || echo "?")
          srv=$(cat "$SERVER_PIDFILE" 2>/dev/null || true)
          if [ -z "$srv" ] || ! kill -0 "$srv" 2>/dev/null; then
            info "  the server exited during the prompt (likely out of memory)"
          else
            peak=$(footprint -p "$srv" 2>/dev/null | awk '/phys_footprint_peak:/ { print $2, $3 }' || true)
            # An answer, right or wrong, means the prompt fit: oMLX rejects
            # prompts that don't, rather than cutting them.
            if printf '%s' "$resp" | "$JQ" -e '.content[0].text' >/dev/null 2>&1; then
              result_w=$w
              case "$result" in
                *"$expected"*) pass "memory test: $alias window $w: a $sent-token prompt answered correctly in $secs s (server peak ${peak:-unknown})" ;;
                *) pass "memory test: $alias window $w: a $sent-token prompt fit, answered in $secs s (server peak ${peak:-unknown}); the answer '${result:0:40}' wasn't the expected '$expected'" ;;
              esac
              break
            fi
            info "  window $w failed after $secs s: ${result:0:160}"
          fi
          w=$(( w - stepw ))
        done
        if [ -n "$result_w" ]; then
          if [ "$result_w" -eq "$start_w" ]; then
            clear_window "$alias"
          else
            set_window "$alias" "$result_w"
            info "  recorded window $result_w for $alias in $WINDOWS_FILE (built-in: $start_w)"
          fi
        else
          fail "memory test: $alias failed at every window down to $floor (see INSTALL.md step 7)"
        fi
      done
    done
    rm -rf "$memdir"
    # Leave a fresh server with this Mac's default model loaded.
    "$WRAPPER" --local-stop >/dev/null 2>&1 || true
  fi
fi

# Load the default model, so the first session doesn't wait for it.
"$WRAPPER" --local-start >/dev/null 2>&1 \
  || warn "couldn't load the default model; the next claude-local launch will start it"

if [ "$(settings_sha)" = "$(cat "$BASELINE/sha.txt")" ]; then
  pass "normal Claude Code settings unchanged"
else
  fail "normal Claude Code settings differ from the baseline in $BASELINE"
fi
# Compare only who is logged in and how; other status fields can vary.
login_fields() {  # the JSON fields, or the raw text if it isn't JSON
  local raw
  raw=$(cat)
  printf '%s' "$raw" | "$JQ" -S '{loggedIn, authMethod, email, orgId}' 2>/dev/null || printf '%s\n' "$raw"
}
if [ "$("$CLAUDE_BIN" auth status 2>/dev/null | login_fields)" = "$(login_fields < "$BASELINE/auth.txt")" ]; then
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
echo
echo "Next:"
echo "  claude-local                        interactive session with this Mac's default model ($default_profile)"
has_vision fast && echo "  claude-local --local-fast --local-vision   the fast model with image input"
for p in fast quality laguna; do
  [ "$p" = "$default_profile" ] && continue
  case " $want " in *" $p "*) printf '  %-35s %s\n' "claude-local --local-$p" "the $p model, $(cat_field "$p" alias)" ;; esac
done
echo "  claude-local --local-status         this Mac's models, windows, server and memory warnings"
echo "  claude-local --local-stop           stop the server and free the model's memory"
[ "$class" != 16 ] && echo "In a session, /context should show about 16K tokens used."
[ "$problems" -eq 0 ]
