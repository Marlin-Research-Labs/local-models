# Installing `claude-local` on a Mac

These steps set up `claude-local`, a second command that runs Claude Code against a local open-weight model served on the Mac itself. The normal `claude` command, its login, settings and history are left untouched. Nothing here needs admin rights.

Tested on September 27, 2026 with:

| Component | Version |
|---|---|
| Mac | MacBook Pro, Apple M5 Max (32-core GPU), 36 GB, macOS 27.0 |
| Claude Code | 2.1.283, native installer (`~/.local/bin/claude`) |
| Inference server | oMLX 0.7.0rc1 (`oMLX-0.7.0rc1-macos26-27.dmg`) |
| Model | `unsloth/Qwen3.6-35B-A3B-UD-MLX-4bit` (21.66 GB) |

What you end up with:

| Piece | Location |
|---|---|
| Wrapper command | `~/.local/bin/claude-local` |
| Claude Code profile for local sessions | `~/.claude-local/` (its own settings, history, sessions and Keychain entry) |
| Inference server app | `~/Applications/oMLX.app`, run headless by the wrapper on `127.0.0.1:8765` |
| Server config, model, cache, logs | `~/.omlx/` |

> **Privacy note.** Inference is local, but any organization-managed Claude Code settings still apply to `claude-local`: hooks, telemetry and so on, under `/Library/Application Support/ClaudeCode/managed-settings.json`. On a managed Mac, prompts and tool events may still leave the machine exactly as they do with normal `claude`. Nothing in this guide bypasses managed settings. Never "fix" this with `--bare` or `CLAUDE_CODE_SIMPLE`.

## Quick install with the script

`install-claude-local.sh` sits next to this file and automates every step below. Copy it to the Mac and run it:

```sh
chmod +x install-claude-local.sh
./install-claude-local.sh                  # install, then run the quick checks (about 1 minute after downloads)
./install-claude-local.sh --memory-test    # also run the full-context memory test from step 8g
./install-claude-local.sh --no-verify      # install only
```

What the script does:
- Checks the Mac first. It stops if the Mac has less than 36 GB of memory unless you pass `--force`.
- Verifies the oMLX download's SHA-256 and Apple's signature and notarization.
- Picks the memory guard tier from the Mac's GPU budget.
- Skips anything already done: a matching oMLX version, model files already complete, configs already set.
- Merges its settings into existing oMLX configs, saving any originals as `*.pre-claude-local`.
- Never overwrites an existing `~/.claude-local/settings.json`, and backs up an older wrapper before replacing it.
- Never uses sudo.
- Exits non-zero if any check fails.

The rest of this document is the manual equivalent, and the reference for what the script does.

## Manual install

All commands are for Terminal (zsh), run as your normal user. Run each step's block in order.

---

### 1. Check the Mac

```sh
sysctl -n machdep.cpu.brand_string                           # needs Apple Silicon
echo "$(( $(sysctl -n hw.memsize) / 1073741824 )) GB RAM"     # see sizing in step 7
system_profiler SPDisplaysDataType | grep -m1 "Total Number of Cores"
sw_vers -productVersion                                      # 26.x/27.x (macOS 15 also works, see step 2)
ls -l ~/.local/bin/claude && claude --version                # Claude Code native install
/usr/bin/jq --version                                        # ships with macOS 15 and later
df -h ~ | tail -1                                            # need ~25 GB now, up to 50 GB more for cache
lsof -nP -iTCP:8765 -sTCP:LISTEN || echo "port 8765 is free"
```

Requirements:
- **Apple Silicon with at least 36 GB of memory.** Step 7 explains how to size this for other Macs. A 32 GB Mac is not enough for this model at a usable context.
- **Claude Code installed normally and logged in.** If `~/.local/bin/claude` doesn't exist, the wrapper falls back to whichever `claude` is on your `PATH`.
- **`~/.local/bin` on your `PATH`.** The native installer already sets this up.

Record a baseline of the normal Claude Code setup so you can prove later that it didn't change:

```sh
mkdir -p ~/claude-local-baseline
shasum -a 256 ~/.claude/settings.json ~/.claude/CLAUDE.md 2>/dev/null > ~/claude-local-baseline/sha.txt
claude auth status > ~/claude-local-baseline/auth.txt 2>&1
cat ~/claude-local-baseline/sha.txt
```

### 2. Install oMLX into `~/Applications` (no admin)

This downloads the pinned release, verifies it against GitHub's published SHA-256, checks Apple's signature and notarization, and copies the app into `~/Applications`.

```sh
OMLX_TAG=v0.7.0rc1
if [ "$(sw_vers -productVersion | cut -d. -f1)" -ge 26 ]; then FLAVOR=macos26-27; else FLAVOR=macos15-sequoia; fi
ASSET=$(curl -fsSL "https://api.github.com/repos/jundot/omlx/releases/tags/$OMLX_TAG" \
  | /usr/bin/jq -r --arg f "$FLAVOR" '.assets[] | select(.name | endswith($f + ".dmg")) | "\(.browser_download_url) \(.digest)"')
DMG_URL=${ASSET%% *}; DMG_SHA=${ASSET##*sha256:}
echo "$DMG_URL"

mkdir -p ~/Downloads/omlx && cd ~/Downloads/omlx
curl -fL --retry 3 -C - -o "omlx-$OMLX_TAG.dmg" "$DMG_URL"
echo "$DMG_SHA  omlx-$OMLX_TAG.dmg" | shasum -a 256 -c -      # must print: OK

MNT=$(mktemp -d)
hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "omlx-$OMLX_TAG.dmg"
codesign --verify --deep --strict "$MNT/oMLX.app" && echo "signature OK"
spctl -a -vv -t exec "$MNT/oMLX.app"                         # expect: accepted, Notarized Developer ID
mkdir -p ~/Applications
ditto "$MNT/oMLX.app" ~/Applications/oMLX.app
hdiutil detach "$MNT"
cd ~
~/Applications/oMLX.app/Contents/MacOS/omlx-cli --version     # expect: 0.7.0rc1
```

On macOS 27, `hdiutil` prints a deprecation warning suggesting `diskutil image`. The commands still work, and `hdiutil` also works on macOS 15.

For reference, the macOS 26/27 DMG for 0.7.0rc1 has SHA-256 `82c1ea4d882153bb2da5cd2793e950620b2d2eb81b2e90695272e878be79b83a`. It is signed "Developer ID Application: Heejun Kim (PSK5Q5T46L)".

> **Do not open oMLX.app from Finder.** `claude-local` runs oMLX's bundled command-line server directly. When the menu-bar app can't write to `/opt/homebrew/bin` or `/usr/local/bin` (the usual case without admin rights), it adds a PATH block to your shell startup files. It would also start its own server at login. Neither is needed.
>
> If macOS says the app is damaged, re-download it. If your endpoint security blocks the app, ask IT to allow `app.omlx` (team `PSK5Q5T46L`).

### 3. Download the model (~21.7 GB, resumable)

```sh
REPO=unsloth/Qwen3.6-35B-A3B-UD-MLX-4bit
DEST=~/.omlx/models/Qwen3.6-35B-A3B-UD-MLX-4bit
mkdir -p "$DEST"
curl -fsSL "https://huggingface.co/api/models/$REPO/tree/main?recursive=true" \
  | /usr/bin/jq -r '.[] | select(.type == "file" and .path != ".gitattributes") | "\(.path) \(.lfs.size // .size)"' \
  > "$DEST/.filelist"
while read -r f sz; do
  out="$DEST/$f"; mkdir -p "$(dirname "$out")"
  for try in 1 2 3 4 5; do
    [ "$(stat -f %z "$out" 2>/dev/null || echo 0)" = "$sz" ] && break
    curl -fL --retry 5 --retry-delay 5 -C - -o "$out" "https://huggingface.co/$REPO/resolve/main/$f"
  done
  if [ "$(stat -f %z "$out" 2>/dev/null || echo 0)" = "$sz" ]; then echo "OK   $f"; else echo "FAIL $f"; fi
done < "$DEST/.filelist"
```

Every line must say `OK`. If any say `FAIL`, run the block again; it resumes where it stopped. The five `model-0000N-of-00005.safetensors` files make up almost all of the 21.66 GB.

### 4. Configure oMLX

If `~/.omlx/settings.json` or `~/.omlx/model_settings.json` already exist from an earlier oMLX install, back them up first. On first start the server fills in every other setting with its defaults.

```sh
mkdir -p ~/.omlx
cat > ~/.omlx/settings.json <<'EOF'
{
  "version": "1.0",
  "server": {
    "host": "127.0.0.1",
    "port": 8765,
    "log_level": "info"
  },
  "scheduler": {
    "max_concurrent_requests": 1
  },
  "cache": {
    "enabled": true,
    "ssd_cache_max_size": "50GB",
    "hot_cache_max_size": "0"
  },
  "memory": {
    "prefill_memory_guard": true,
    "memory_guard_tier": "aggressive"
  },
  "sampling": {
    "max_context_window": 163840,
    "max_tokens": 32768
  }
}
EOF

cat > ~/.omlx/model_settings.json <<'EOF'
{
  "version": 1,
  "models": {
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
    }
  }
}
EOF
```

What these settings do:

| Setting | Why |
|---|---|
| `host` 127.0.0.1, `port` 8765 | Local only. Port 8765 avoids the common dev-server port 8000. |
| `max_concurrent_requests` 1 | One generation at a time. Parallel requests would each need their own KV cache and would evict the prefix cache. oMLX's default is 8. |
| `ssd_cache_max_size` 50GB | The prefix cache lives on the SSD. The default would take about half the free disk. |
| `memory_guard_tier` aggressive | Lets a prompt use up to 95% of the GPU budget instead of 90%. Needed for a 128K window on a 36 GB Mac (step 7). |
| `model_type_override` llm | Loads the model text-only, skipping its 0.9 GB vision tower (resident size 19.7 GB instead of 20.8 GB). |
| `model_alias` qwen3.6-35b-a3b | The name Claude Code uses. It must **not** start with `claude-`, or Claude Code ignores its context-window override. |
| `max_context_window` 163840 | The server-side limit. It is larger than Claude Code's 131072 window so tokenizer differences never cause rejections. |
| Sampling 0.6 / 0.95 / 20 / 0 / 0 | Qwen's recommended "thinking mode, precise coding" settings. Claude Code sends no temperature while thinking is on, so these apply. |
| `enable_thinking`, `preserve_thinking` true | Keeps reasoning across turns, which Qwen recommends for agents and which keeps the prompt prefix stable for caching. |
| `ttl_seconds` 1800 | Unloads the ~20 GB model after 30 minutes idle. The server process stays up and is small. |

### 5. Create the isolated Claude Code profile

`claude-local` sets `CLAUDE_CONFIG_DIR=~/.claude-local`, so local sessions get their own settings, history, trust decisions and Keychain entry. This block copies only your theme, hooks and transcript-retention setting from the normal profile, links your personal `CLAUDE.md`, and adds the local-model settings.

```sh
mkdir -p ~/.claude-local
[ -e ~/.claude/CLAUDE.md ] && ln -sfn ~/.claude/CLAUDE.md ~/.claude-local/CLAUDE.md
if [ -e ~/.claude-local/settings.json ]; then
  echo "~/.claude-local/settings.json already exists; leaving it alone"
else
  { [ -f ~/.claude/settings.json ] && cat ~/.claude/settings.json || echo '{}'; } \
    | /usr/bin/jq '{cleanupPeriodDays, theme, hooks} | with_entries(select(.value != null))
        + {effortLevel: "medium", useAutoModeDuringPlan: false, disableClaudeAiConnectors: true,
           permissions: {defaultMode: "default"}}' > ~/.claude-local/settings.json
fi
/usr/bin/jq 'del(.hooks)' ~/.claude-local/settings.json
```

- **Permission prompts:** `permissions.defaultMode: "default"` gives normal prompting instead of auto mode. In auto mode, the tool-call safety checks would be judged by the local model.
- **Hooks:** hooks are copied so, for example, iTerm2 status integration keeps working. If your normal hooks call anything that shouldn't run for local sessions, remove it from `~/.claude-local/settings.json`.

### 6. Install the `claude-local` wrapper

```sh
mkdir -p ~/.local/bin
cat > ~/.local/bin/claude-local <<'CLAUDE_LOCAL_SCRIPT'
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
chmod +x ~/.local/bin/claude-local
bash -n ~/.local/bin/claude-local && echo "syntax OK"
claude-local --local-status
```

What the wrapper does:

- **On each launch:**
  - Warns if OrbStack's VM, Ollama or LM Studio are holding memory.
  - Starts the oMLX server if it isn't running, in its own process group so Ctrl-C in Claude Code can't kill it.
  - Waits until the model is listed.
- **For the Claude Code process only (nothing global), it sets:**
  - the local endpoint and a dummy token;
  - every model tier mapped to the one local model;
  - the real context window (Claude Code assumes 200K for unknown models);
  - prompt-cache stability switches;
  - compatibility switches for a non-Anthropic backend;
  - single-slot limits and long timeouts.
- **Tools and MCP:** WebSearch (an Anthropic server-side tool) and LSP are disabled, and MCP servers are off (`--strict-mcp-config`). Pass `--mcp-config <file>` to add servers for one session.
- **Subcommands** such as `claude-local mcp list` or `claude-local doctor` pass straight through to Claude Code.

### 7. Size the context window for this Mac

The model's weights take 19.7 GB. What remains of macOS's GPU memory budget decides how long a context fits. Read the budget with oMLX's bundled Python:

```sh
OMLX_RES=~/Applications/oMLX.app/Contents/Resources/Python
PYTHONHOME=$OMLX_RES/cpython-3.11 PYTHONPATH=$OMLX_RES/framework-mlx-base/lib/python3.11/site-packages \
  "$OMLX_RES/cpython-3.11/bin/python3" -c "import mlx.core as mx; i = mx.device_info(); \
  print('GPU budget:', round(i['max_recommended_working_set_size'] / 2**30, 1), 'GiB of', round(i['memory_size'] / 2**30), 'GiB')"
```

| GPU budget | `memory_guard_tier` | `CLAUDE_LOCAL_CTX` | Status |
|---|---|---|---|
| ≥ 34 GiB (typically 48 GB Macs and up) | `balanced` or `aggressive` | 131072 | Expected to fit comfortably (not tested) |
| ~28 GiB (36 GB Macs) | `aggressive` | 131072 | **Tested.** The largest prompt Claude Code sends at this window (~108K tokens) works: 55 s cold, 5 s when the prefix is cached. Raw prompts near 131K were sometimes accepted and sometimes rejected by the guard, depending on other memory use. With `balanced`, prompts were rejected from ~78K. |
| < 27 GiB (32 GB Macs and below) | — | — | Not supported by this guide. Claude Code needs ≥ 64K of context, and there isn't room for it next to this model. |

Rough rule from the measurement: during prompt processing the server's footprint grows by about 0.05 GB per 1K tokens of context on top of the weights. The guard allows up to 95% of the budget (`aggressive`) or 90% (`balanced`).

- **Changing the window:** edit the `ctx="${CLAUDE_LOCAL_CTX:-131072}"` line in `~/.local/bin/claude-local`. Keep `max_context_window` in `~/.omlx/model_settings.json` larger than it.
- **Below 131072:** also set `CLAUDE_LOCAL_MAX_OUT` to 16384.
- **Not below 65536:** Claude Code's own prompt and tools take about 16K tokens, and it reserves about 33K before auto-compacting.
- **Don't raise the budget:** don't raise `iogpu.wired_limit_mb` with sudo to work around this. It affects the whole system and needs admin rights.

### 8. Verify

Stop OrbStack or other large memory users first if they're running (`orbctl stop`).

**a. Start the server and load the model** (about 10–15 s the first time):

```sh
claude-local --local-start
claude-local --local-status
```

**b. Raw API check.** Expect a thinking block, then the text "391":

```sh
curl -sS http://127.0.0.1:8765/v1/messages -H "Authorization: Bearer local" \
  -H "content-type: application/json" -H "anthropic-version: 2023-06-01" \
  -d '{"model":"qwen3.6-35b-a3b","max_tokens":2000,"thinking":{"type":"adaptive"},
       "messages":[{"role":"user","content":"What is 17*23? Answer with just the number."}]}' \
  | /usr/bin/jq '{stop_reason, usage, content: [.content[] | {type, text: ((.text // .thinking)[0:120])}]}'
```

**c. Tool-call check.** Expect `"stop_reason": "tool_use"` and a `Bash` call with `ls /tmp`:

```sh
curl -sS http://127.0.0.1:8765/v1/messages -H "Authorization: Bearer local" \
  -H "content-type: application/json" -H "anthropic-version: 2023-06-01" \
  -d '{"model":"qwen3.6-35b-a3b","max_tokens":4000,"thinking":{"type":"adaptive"},
       "tools":[{"name":"Bash","description":"Run a shell command.","input_schema":{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}}],
       "messages":[{"role":"user","content":"List the files in /tmp using the Bash tool."}]}' \
  | /usr/bin/jq '{stop_reason, calls: [.content[] | select(.type == "tool_use") | {name, input}]}'
```

**d. Claude Code in print mode.** Expect `OK` in a few seconds:

```sh
mkdir -p /tmp/claude-local-test && cd /tmp/claude-local-test
claude-local -p "Reply with exactly the word OK and nothing else."
```

**e. Agentic coding test.** This took 6 turns and about 30 s on the tested Mac:

```sh
rm -rf /tmp/claude-local-agentic && mkdir -p /tmp/claude-local-agentic && cd /tmp/claude-local-agentic && git init -q
claude-local -p "Create a Python module textstats.py with word_frequencies(text: str) -> dict[str, int] (lowercase, strip punctuation, count words) and top_n(text: str, n: int) -> list[tuple[str, int]] (sorted by count descending, then word ascending). Create test_textstats.py with unittest tests for an empty string, punctuation and ties. Run python3 -m unittest -v and fix failures until all pass. Finish with a one-line summary." \
  --permission-mode acceptEdits \
  --allowedTools "Read,Write,Edit,Glob,Grep,Bash(python3 -m unittest *),Bash(python3 -m unittest)"
python3 -m unittest -v 2>&1 | tail -3      # confirm independently: OK
```

**f. Interactive session.** First launch shows the theme picker, security notes and a folder-trust prompt, once per profile and folder:

```sh
cd /tmp/claude-local-test && claude-local
```

The header should read `qwen3.6-35b-a3b with medium effort`. In the session:
- Run `/context`. Expect about 16K of 131.1K tokens used, no MCP tools, and an auto-compact buffer of about 33K.
- Ask a question to confirm it answers.
- `/exit`.

**g. Memory acceptance test at full context.** This sends one prompt at the largest size Claude Code can send for your window, then reports the answer and the server's peak memory. Claude Code auto-compacts at the window minus about 33K and refuses to send more than the window minus about 23K (with the default 32K max output), so the test uses about 108K tokens for a 131072 window.

```sh
CTX=131072
OMLX_RES=~/Applications/oMLX.app/Contents/Resources/Python
PYTHONHOME=$OMLX_RES/cpython-3.11 PYTHONPATH=$OMLX_RES/framework-mlx-base/lib/python3.11/site-packages \
  "$OMLX_RES/cpython-3.11/bin/python3" - "$CTX" > /tmp/claude-local-long.json <<'PY'
import glob, json, os, sys, sysconfig
target = int((int(sys.argv[1]) - 23000) * 3.8)   # Claude Code's largest prompt: window - 23K tokens, ~3.8 chars/token
text = ""
for f in sorted(glob.glob(os.path.join(sysconfig.get_paths()["stdlib"], "*.py"))):
    text += f"\n##### FILE: {os.path.basename(f)}\n" + open(f, encoding="utf-8", errors="replace").read()
    if len(text) >= target:
        break
text = text[:target]
last = text[text.rindex("##### FILE: ") + 12:].split("\n", 1)[0]
q = "\n\nQuestion: What is the file name in the very last '##### FILE:' header above? Reply with only the file name."
print(json.dumps({"model": "qwen3.6-35b-a3b", "max_tokens": 200, "thinking": {"type": "disabled"},
                  "messages": [{"role": "user", "content": text + q}]}))
print(f"expected answer: {last}", file=sys.stderr)
PY
H=(-H "Authorization: Bearer local" -H "content-type: application/json" -H "anthropic-version: 2023-06-01")
curl -sS "${H[@]}" http://127.0.0.1:8765/v1/messages/count_tokens -d @/tmp/claude-local-long.json; echo
time curl -sS -m 1200 "${H[@]}" http://127.0.0.1:8765/v1/messages -d @/tmp/claude-local-long.json \
  | /usr/bin/jq '{stop_reason, answer: .content[0].text, usage, error}'
footprint -p "$(cat ~/.omlx/claude-local-server.pid)" | grep phys_footprint
```

- **Pass:** the answer matches the "expected answer" line and `phys_footprint_peak` stays below the GPU budget from step 7. The tested Mac took 55 s for 105.7K tokens and peaked at 27 GB.
- **Warm path:** run the `time curl` line again. It should answer in about a second from the prefix cache.
- **Fail:** if the result is an error mentioning "Prefill context too large", lower the context window (step 7) and re-run with the new `CTX`.

**h. Normal `claude` is unchanged.** Both commands should report no difference:

```sh
shasum -a 256 ~/.claude/settings.json ~/.claude/CLAUDE.md 2>/dev/null | diff - ~/claude-local-baseline/sha.txt && echo "settings unchanged"
claude auth status | diff - ~/claude-local-baseline/auth.txt && echo "login unchanged"
```

## Daily use

```sh
claude-local                    # interactive; takes the same flags as claude
claude-local -p "question"      # print mode
claude-local --continue         # resume the last local session in this folder
claude-local --local-status     # server, model and memory warnings
claude-local --local-start      # warm the model before you need it
claude-local --local-stop       # stop the server and free ~20 GB now
claude-local --local-help
```

Expect:
- **Speed:** about 70–90 tokens/s generation, and about 1,500–1,900 tokens/s prefill on long prompts. After the first turn most of the prompt comes from the cache (about 98% hits in testing).
- **Memory:** for best results, close memory-heavy apps and stop VMs before long sessions.

Per-invocation overrides: `CLAUDE_LOCAL_CTX`, `CLAUDE_LOCAL_MAX_OUT`, `CLAUDE_LOCAL_MODEL`, `CLAUDE_LOCAL_PORT`. For example: `CLAUDE_LOCAL_CTX=65536 CLAUDE_LOCAL_MAX_OUT=16384 claude-local`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `port 8765 is in use ... does not serve 'qwen3.6-35b-a3b'` | Something else owns the port (`lsof -nP -iTCP:8765`). Stop it, or use another port: `CLAUDE_LOCAL_PORT=8766 claude-local`. |
| `oMLX did not list 'qwen3.6-35b-a3b' within 90 s` or `oMLX exited during startup` | Read `~/.omlx/logs/claude-local-server.log`. The model folder name under `~/.omlx/models/` must match the key in `model_settings.json`. |
| An API error mentioning "Prefill context too large" | The prompt didn't fit in GPU memory. Close large apps, stop VMs or other model servers, or lower the context window (step 7). |
| The model ignores the prompt or invents a task | Make sure you are on the oMLX backend (`--local-status`). The optional Ollama backend (`CLAUDE_LOCAL_BACKEND=ollama`) misbehaved this way on Ollama 0.30.10 and needs a newer Ollama. |
| Slow first reply in a new session | The prompt prefix is being processed cold (about 16K tokens, a few seconds). Later turns reuse the SSD prefix cache. |
| Everything is slow, or the Mac is swapping | Another large memory user is running: OrbStack or Docker VMs, Ollama or LM Studio with a model loaded. `claude-local` warns about these at launch. |
| Claude Code updated and `claude-local` broke | Normal `claude` is unaffected. Run `claude-local -p "Reply OK"` and read the error. Check the environment variables in the wrapper against the new release's docs. |

## Updating

- **oMLX:** repeat step 2 with a new `OMLX_TAG`. Stop the server first with `claude-local --local-stop`. The config in `~/.omlx` is kept. Re-run steps 8b–8g.
- **Model:** download into a new folder under `~/.omlx/models/` and add an entry for it to `model_settings.json` with its own alias (not starting with `claude-`). Run it with `CLAUDE_LOCAL_MODEL=<alias> claude-local`. Re-run step 8g, because memory use changes with the model.
- **Claude Code:** it updates itself as usual. After a major update, re-run steps 8d and 8e.

## Uninstall

```sh
claude-local --local-stop
rm ~/.local/bin/claude-local ~/.local/bin/claude-local.bak-* 2>/dev/null
rm -rf ~/.claude-local ~/.omlx ~/Applications/oMLX.app ~/Downloads/omlx ~/claude-local-baseline
```

If oMLX was already set up on the Mac before `claude-local`, don't delete `~/.omlx`. Remove the model folder you don't want, then restore the originals from `~/.omlx/*.pre-claude-local`.

## Design notes

- **Why this model:** Qwen3.6-35B-A3B is a mixture-of-experts model with 3B active parameters, so it runs at about 80+ tokens/s on a 32-core M5 Max. Only 10 of its 40 layers keep a normal attention cache (about 20 KiB per token), so long contexts are cheap.
- **A newer option:** Qwen3.8-27B (August 2026) scores higher on vendor benchmarks but runs 3–5× slower on this class of GPU. Its chat template also rejects some Claude Code messages, so it is a possible future "quality" option, not the default.
- **Why the Unsloth build:** its dynamic 4-bit quantization measures about 3× closer to the full-precision model than uniform 4-bit (KL divergence 0.029 vs 0.088), for about 1 GB more. 5-bit and larger don't leave room for context on a 36 GB Mac.
- **Why oMLX:** it serves the Anthropic Messages API natively. It removes Claude Code's cache-breaking per-request markers, accepts mid-conversation system messages and adaptive thinking, and has a paged prefix cache on SSD. Version 0.7.0rc1 or later is needed for the bounded long-prompt attention path and the partial-block cache reuse for this model family.
- **Why not 32K context:** Claude Code auto-compacts at the window minus about 33K, which a 32K window is already below.
