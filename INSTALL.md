# Installing `claude-local` on a Mac

These steps set up `claude-local`, a second command that runs Claude Code against a local open-weight model served on the Mac itself. The normal `claude` command, its login, settings and history are left untouched. Nothing here needs admin rights.

Tested on September 27, 2026 with:

| Component | Version |
|---|---|
| Mac | MacBook Pro, Apple M5 Max (32-core GPU), 36 GB, macOS 27.0 |
| Claude Code | 2.1.283, native installer (`~/.local/bin/claude`) |
| Inference server | oMLX 0.7.0rc1 (`oMLX-0.7.0rc1-macos26-27.dmg`) |
| Fast model (default) | `unsloth/Qwen3.6-35B-A3B-UD-MLX-4bit` (21.66 GB) |
| Quality model (optional) | `Jundot/Qwen3.8-27B-oQ4e-mtp` (16.99 GB) |

What you end up with:

| Piece | Location |
|---|---|
| Wrapper command | `~/.local/bin/claude-local` |
| Claude Code profile for local sessions | `~/.claude-local/` (its own settings, history, sessions and Keychain entry) |
| Inference server app | `~/Applications/oMLX.app`, run headless by the wrapper on `127.0.0.1:8765` |
| Server config, models, cache, logs | `~/.omlx/` |
| Saved model and vision defaults | `~/.config/claude-local/defaults` (or `$XDG_CONFIG_HOME/claude-local/defaults` if you set that), only if you save one |

Each launch picks a model and whether image input (vision) is on:

| Choice | Model | Context window | Generation | Best for |
|---|---|---|---|---|
| `claude-local` | fast, text only | 128K | ~70–90 tok/s | Everyday coding (the default) |
| `claude-local --local-vision` | fast, with images | 104K | ~70–90 tok/s | Screenshots, diagrams, UI work |
| `claude-local --local-quality` | quality, text only | 92K | ~20–45 tok/s | Harder tasks where speed matters less |
| `claude-local --local-quality --local-vision` | quality, with images | 80K | ~20–45 tok/s | Harder tasks with images |

Only one model fits in memory at a time; switching between them takes about 5–15 s the first time.

> **Privacy note.** Inference is local, but any organization-managed Claude Code settings still apply to `claude-local`: hooks, telemetry and so on, under `/Library/Application Support/ClaudeCode/managed-settings.json`. On a managed Mac, prompts and tool events may still leave the machine exactly as they do with normal `claude`. Nothing in this guide bypasses managed settings. Never "fix" this with `--bare` or `CLAUDE_CODE_SIMPLE`.

## Quick install with the script

`install-claude-local.sh` sits next to this file and automates every step below. Copy it to the Mac and run it:

```sh
chmod +x install-claude-local.sh
./install-claude-local.sh
```

| Command | What it does |
|---|---|
| `./install-claude-local.sh` | Fast model, then the quick checks (about 1 minute after downloads) |
| `./install-claude-local.sh --with-quality` | Also the quality model (17 GB more); safe to add later |
| `./install-claude-local.sh --memory-test` | Also test every installed model and vision setting at full context |
| `./install-claude-local.sh --no-verify` | Install only |
| `./install-claude-local.sh --restart-server` | Restart the server to load new models even if it looks busy |

What the script does:
- Checks the Mac first. It stops if the Mac has less than 36 GB of memory unless you pass `--force`.
- Restarts the server only when it has new models or settings and no session seems to be using it. A request in flight, one in the last 10 minutes, or a status it can't read counts as in use; `--restart-server` overrides this.
- Downloads models pinned to exact Hugging Face revisions and checks every file's size. New downloads land in `~/.omlx/downloads` and move into `~/.omlx/models` only when complete.
- Sets up the vision variants (symlinks, no extra disk).
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
sysctl -n machdep.cpu.brand_string
echo "$(( $(sysctl -n hw.memsize) / 1073741824 )) GB RAM"
system_profiler SPDisplaysDataType | grep -m1 "Total Number of Cores"
sw_vers -productVersion
ls -l ~/.local/bin/claude && claude --version
/usr/bin/jq --version
df -h ~ | tail -1
lsof -nP -iTCP:8765 -sTCP:LISTEN || echo "port 8765 is free"
```

Look for, in order:
- an Apple chip;
- at least 36 GB of memory (see step 7);
- the GPU core count;
- macOS 26 or 27 (macOS 15 also works; see step 2);
- the Claude Code native install;
- a `jq` version, since `jq` ships with macOS 15 and later;
- at least ~25 GB free (plus 17 GB for the quality model, and up to 50 GB more for the prompt cache);
- port 8765 free.

> **Pasting into zsh:** the blocks in this guide have no `#` comments, because zsh doesn't treat `#` as a comment when you paste unless `setopt interactivecomments` is on. Explanations are in the text around each block.

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
echo "$DMG_SHA  omlx-$OMLX_TAG.dmg" | shasum -a 256 -c -

MNT=$(mktemp -d)
hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "omlx-$OMLX_TAG.dmg"
codesign --verify --deep --strict "$MNT/oMLX.app" && echo "signature OK"
spctl -a -vv -t exec "$MNT/oMLX.app"
mkdir -p ~/Applications
ditto "$MNT/oMLX.app" ~/Applications/oMLX.app
hdiutil detach "$MNT"
cd ~
~/Applications/oMLX.app/Contents/MacOS/omlx-cli --version
```

Expect three results:
- `shasum` prints `OK`.
- `spctl` prints `accepted` and `Notarized Developer ID`.
- The last line prints `0.7.0rc1`.

On macOS 27, `hdiutil` prints a deprecation warning suggesting `diskutil image`. The commands still work, and `hdiutil` also works on macOS 15.

For reference, the macOS 26/27 DMG for 0.7.0rc1 has SHA-256 `82c1ea4d882153bb2da5cd2793e950620b2d2eb81b2e90695272e878be79b83a`. It is signed "Developer ID Application: Heejun Kim (PSK5Q5T46L)".

> **Do not open oMLX.app from Finder.** `claude-local` runs oMLX's bundled command-line server directly. When the menu-bar app can't write to `/opt/homebrew/bin` or `/usr/local/bin` (the usual case without admin rights), it adds a PATH block to your shell startup files. It would also start its own server at login. Neither is needed.
>
> If macOS says the app is damaged, re-download it. If your endpoint security blocks the app, ask IT to allow `app.omlx` (team `PSK5Q5T46L`).

### 3. Download the models (resumable)

This defines a small download function, `get_model <repo> <revision> <folder>`, then fetches the fast model (21.66 GB) and, optionally, the quality model (16.99 GB). Both are pinned to the exact Hugging Face revisions that were tested. Don't start the server until the downloads finish.

```sh
get_model() {
  local repo=$1 rev=$2 dest=~/.omlx/models/$3
  mkdir -p "$dest"
  curl -fsSL "https://huggingface.co/api/models/$repo/tree/$rev?recursive=true" \
    | /usr/bin/jq -r '.[] | select(.type == "file" and .path != ".gitattributes") | "\(.path) \(.lfs.size // .size)"' \
    > "$dest/.filelist"
  while read -r f sz; do
    out="$dest/$f"; mkdir -p "$(dirname "$out")"
    for try in 1 2 3 4 5; do
      [ "$(stat -f %z "$out" 2>/dev/null || echo 0)" = "$sz" ] && break
      curl -fL --retry 5 --retry-delay 5 -C - -o "$out" "https://huggingface.co/$repo/resolve/$rev/$f"
    done
    if [ "$(stat -f %z "$out" 2>/dev/null || echo 0)" = "$sz" ]; then echo "OK   $f"; else echo "FAIL $f"; fi
  done < "$dest/.filelist"
}

get_model unsloth/Qwen3.6-35B-A3B-UD-MLX-4bit 6700c3e5bdeb050a379c8d2a4133f43f3647f20f Qwen3.6-35B-A3B-UD-MLX-4bit

```

Optionally, the quality model:

```sh
get_model Jundot/Qwen3.8-27B-oQ4e-mtp 04dc5509edd8670fc78cc8c2f74bf9b77b1f2acc Qwen3.8-27B-oQ4e-mtp
```

Every line must say `OK`. If any say `FAIL`, run that `get_model` line again; it resumes where it stopped.

Then create the vision variants. Each is a symlink to the same weights under a second folder name, which oMLX treats as a separate model and serves with its vision engine:

```sh
cd ~/.omlx/models
ln -sfn Qwen3.6-35B-A3B-UD-MLX-4bit Qwen3.6-35B-A3B-UD-MLX-4bit-vision
[ -d Qwen3.8-27B-oQ4e-mtp ] && ln -sfn Qwen3.8-27B-oQ4e-mtp Qwen3.8-27B-oQ4e-mtp-vision
cd ~
```

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
| `memory_guard_tier` aggressive | Lets a prompt use up to 95% of the GPU budget instead of 90%. Needed for the context windows in step 7 on a 36 GB Mac. |
| `model_type_override` llm / vlm | `llm` loads a model text-only, skipping its vision tower (the fast model then takes 19.7 GB instead of 20.8 GB). The `-vision` entries use `vlm`, oMLX's vision engine. |
| `model_alias` | The names Claude Code uses: `qwen3.6-35b-a3b`, `qwen3.8-27b`, and each with `-vision`. They must **not** start with `claude-`, or Claude Code ignores its context-window override. |
| `max_context_window` 163840 | The server-side limit. It is larger than any window Claude Code is given, so tokenizer differences never cause rejections; the memory guard is what really limits context. |
| Fast sampling 0.6 / 0.95 / 20 / 0 / 0 | Qwen's recommended "thinking mode, precise coding" settings for Qwen3.6. Claude Code sends no temperature while thinking is on, so these apply. |
| Quality sampling 1.0 / 0.95 / 20 / 0 / 0 | Qwen's recommended thinking-mode settings for Qwen3.8, which its benchmarks used. |
| Quality `reasoning_effort` medium | Qwen3.8 defaults to `xhigh`, which can think for minutes on hard prompts at this model's speed. On a test coding task `xhigh` took 73 s against 57 s for `medium`, with the same result. Set it to `xhigh` here if you want Qwen's default. Claude Code's `/effort` setting doesn't reach it. |
| Quality `mtp_enabled` true (text only) | Qwen3.8's multi-token-prediction head drafts about 3.6 tokens per step (88–97% accepted). It's left off for the vision variant until that's been verified. |
| `enable_thinking`, `preserve_thinking` true | Keeps reasoning across turns, which Qwen recommends for agents and which keeps the prompt prefix stable for caching. |
| `ttl_seconds` 1800 | Unloads a model after 30 minutes idle. The server process stays up and is small. |

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
# Models, served by oMLX (~/Applications/oMLX.app) on http://127.0.0.1:8765:
#   fast     Qwen3.6-35B-A3B (Unsloth UD-MLX-4bit), the default
#   quality  Qwen3.8-27B (oMLX oQ4e-mtp), slower but stronger; install it with
#            install-claude-local.sh --with-quality
# Either model can run with image input (vision) on or off (the default).
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
#   --local-fast | --local-quality       choose the model (default: fast)
#   --local-vision | --local-no-vision   image input on or off (default: off)
#   --local-set-default   save the model and vision options given, then exit
#   --local-status        show the selection, the server and installed models
#   --local-start         start the server and load the selected model, then exit
#   --local-stop          stop the oMLX server started by claude-local
#   --local-help          show this help
#
# Environment, per invocation: CLAUDE_LOCAL_PROFILE=fast|quality and
# CLAUDE_LOCAL_VISION=on|off. For experiments: CLAUDE_LOCAL_MODEL (served model
# id), CLAUDE_LOCAL_CTX, CLAUDE_LOCAL_MAX_OUT, CLAUDE_LOCAL_PORT and
# CLAUDE_LOCAL_BACKEND=omlx|ollama.
#
# Precedence: option > environment > saved default > built-in. Saved defaults
# live in ~/.config/claude-local/defaults (or $XDG_CONFIG_HOME/claude-local).

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

# --- Wrapper options: a leading run of --local-* arguments ------------------
opt_profile=""
opt_vision=""
cmd=""
while [ $# -gt 0 ]; do
  case "$1" in
    --local-fast) opt_profile=fast ;;
    --local-quality) opt_profile=quality ;;
    --local-vision) opt_vision=on ;;
    --local-no-vision) opt_vision=off ;;
    --local-status|--local-start|--local-stop|--local-help|--local-set-default)
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

# --- Resolve model and vision ------------------------------------------------
saved_profile=""
saved_vision=""
if [ -r "$DEFAULTS_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}              # drop comments
    line=${line//[[:space:]]/}    # drop all whitespace, including CR
    case "$line" in
      "") ;;
      profile=fast|profile=quality) saved_profile=${line#*=} ;;
      vision=on|vision=off) saved_vision=${line#*=} ;;
      *) warn "ignoring '$line' in $DEFAULTS_FILE (expected profile=fast|quality or vision=on|off)" ;;
    esac
  done < "$DEFAULTS_FILE"
fi

env_profile="${CLAUDE_LOCAL_PROFILE:-}"
case "$env_profile" in ""|fast|quality) ;; *) die "CLAUDE_LOCAL_PROFILE must be fast or quality" ;; esac
case "${CLAUDE_LOCAL_VISION:-}" in
  "") env_vision="" ;;
  on|1|yes|true) env_vision=on ;;
  off|0|no|false) env_vision=off ;;
  *) die "CLAUDE_LOCAL_VISION must be on or off" ;;
esac

# Remember where each choice came from, for --local-status.
if [ -n "$opt_profile" ]; then profile=$opt_profile; profile_src="option"
elif [ -n "$env_profile" ]; then profile=$env_profile; profile_src="CLAUDE_LOCAL_PROFILE"
elif [ -n "$saved_profile" ]; then profile=$saved_profile; profile_src="saved default"
else profile=fast; profile_src="built-in"; fi
if [ -n "$opt_vision" ]; then vision=$opt_vision; vision_src="option"
elif [ -n "$env_vision" ]; then vision=$env_vision; vision_src="CLAUDE_LOCAL_VISION"
elif [ -n "$saved_vision" ]; then vision=$saved_vision; vision_src="saved default"
else vision=off; vision_src="built-in"; fi

# One row per model and vision setting: model folder, served alias, the
# context window Claude Code plans for (measured with
# install-claude-local.sh --memory-test), max output tokens, and extra
# Claude Code settings. Vision rows are symlinks to the same weights,
# served by oMLX's vision engine.
profile_row() {  # profile_row <profile> <vision>
  caps=""
  case "$1:$2" in
    fast:off)    dir=Qwen3.6-35B-A3B-UD-MLX-4bit;        alias=qwen3.6-35b-a3b;        row_ctx=131072; row_out=32000 ;;
    fast:on)     dir=Qwen3.6-35B-A3B-UD-MLX-4bit-vision; alias=qwen3.6-35b-a3b-vision; row_ctx=106496; row_out=32000 ;;
    quality:off) dir=Qwen3.8-27B-oQ4e-mtp;               alias=qwen3.8-27b;            row_ctx=94208;  row_out=20000
                 caps="-mid_conv_system" ;;
    quality:on)  dir=Qwen3.8-27B-oQ4e-mtp-vision;        alias=qwen3.8-27b-vision;     row_ctx=81920;  row_out=20000
                 caps="-mid_conv_system" ;;
  esac
}
installed() { [ -f "$OMLX_HOME/models/$1/config.json" ]; }

# Why the model for the current row isn't usable, as a hint for the user.
missing_hint() {
  case "$dir" in
    *-vision) if installed "${dir%-vision}"; then
                echo "its vision variant (~/.omlx/models/$dir) is missing; re-run install-claude-local.sh to create it"
                return
              fi ;;
  esac
  case "$profile" in
    quality) echo "the quality model is not installed; run install-claude-local.sh --with-quality" ;;
    *) echo "the fast model is not installed; run install-claude-local.sh" ;;
  esac
}

if [ "$cmd" = "set-default" ]; then
  [ -n "$opt_profile$opt_vision" ] || die "give --local-fast/--local-quality and/or --local-vision/--local-no-vision to save"
  # Save only what the options say; keep the other saved value. Environment
  # variables are never saved.
  new_profile="${opt_profile:-${saved_profile:-fast}}"
  new_vision="${opt_vision:-${saved_vision:-off}}"
  profile_row "$new_profile" "$new_vision"
  installed "$dir" || { profile=$new_profile; die "can't save that default: $(missing_hint)"; }
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

# Requests the server is working on or has queued ("?" if it can't say).
requests_in_flight() {
  curl -fsS -m 3 -H "Authorization: Bearer $token" "$base_url/api/status" 2>/dev/null \
    | /usr/bin/jq -r '(.active_requests // 0) + (.waiting_requests // 0)' 2>/dev/null || echo "?"
}

# oMLX holds one model at a time here; switching models evicts the other.
# last_access is set when a request starts, so a long generation can look
# idle; the in-flight count covers that.
swap_warning() {
  [ "$backend" = "omlx" ] || return 0
  local other idle busy
  busy=$(requests_in_flight)
  while read -r other idle; do
    [ -n "$other" ] && [ "$other" != "$model" ] || continue
    if [ "$busy" != "0" ] && [ "$busy" != "?" ]; then
      warn "$other is serving a request right now, probably for another session; this launch will wait for it, then swap it out for $model."
    elif [ "$idle" -ge 0 ] && [ "$idle" -lt 600 ]; then
      warn "$other was used ${idle}s ago, probably by another session; this launch swaps it out for $model."
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
  local mark reserve
  # Claude Code compacts at W - min(max output, 20000) - 13000 and refuses
  # to send past W - min(max output, 20000) - 3000.
  reserve=$(( max_out < 20000 ? max_out : 20000 ))
  echo "model:      $profile ($profile_src) -> $model"
  echo "vision:     $vision ($vision_src)"
  echo "context:    $ctx (auto-compact ~$((ctx - reserve - 13000)), hard limit ~$((ctx - reserve - 3000))); max output $max_out"
  if [ "$vision" = "off" ]; then
    echo "images:     off; reading image files is refused, and pasted images aren't seen by the model"
  fi
  echo "backend:    $backend $base_url"
  if server_has_model; then
    local loaded
    loaded=$(loaded_models | awk '{ printf "%s%s (idle %ss)", sep, $1, $2; sep = ", " }')
    echo "server:     up; loaded: ${loaded:-none}"
  else
    echo "server:     down, or '$model' not listed"
  fi
  echo "defaults:   $DEFAULTS_FILE$([ -r "$DEFAULTS_FILE" ] || echo ' (none saved)')"
  echo "claude:     $CLAUDE_BIN"
  echo "omlx:       $OMLX_CLI"
  echo "installed:"
  for p in fast quality; do
    for v in off on; do
      profile_row "$p" "$v"
      if installed "$dir"; then mark="installed    ctx $row_ctx"; else mark="not installed"; fi
      printf '            %-8s vision %-4s %s\n' "$p" "$v" "$mark"
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

# Qwen3.8's chat template rejects system messages after the first one, and
# oMLX then moves them to the front, which breaks the prefix cache.
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

# WebSearch is an Anthropic server-side tool; LSP schema changes break the
# prefix cache.
if [ "$vision" = "off" ]; then
  # Without vision the server drops images silently. A hook on the Read tool
  # refuses image files with a clear message instead. (Deny rules would also
  # hide image files from Glob and Grep.)
  image_hook=$(cat <<'HOOK'
/usr/bin/jq -r '.tool_input.file_path // empty' | /usr/bin/grep -qiE '[.](png|jpe?g|gif|webp)$' || exit 0
printf '%s\n' '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "Image input is off in this claude-local session, so image files cannot be viewed. There is no workaround: do not try to decode, OCR or convert images with shell commands or scripts. Tell the user to relaunch with claude-local --local-vision."}}'
HOOK
)
  hook_settings=$(/usr/bin/jq -cn --arg c "$image_hook" \
    '{hooks: {PreToolUse: [{matcher: "Read", hooks: [{type: "command", command: $c}]}]}}')
  exec "$CLAUDE_BIN" --strict-mcp-config --exclude-dynamic-system-prompt-sections \
    --disallowedTools=WebSearch,LSP "--settings=$hook_settings" "$@"
fi
exec "$CLAUDE_BIN" --strict-mcp-config --exclude-dynamic-system-prompt-sections \
  --disallowedTools=WebSearch,LSP "$@"
CLAUDE_LOCAL_SCRIPT
chmod +x ~/.local/bin/claude-local
bash -n ~/.local/bin/claude-local && echo "syntax OK"
claude-local --local-status
```

What the wrapper does:

- **Model and vision selection** (wrapper options must come before any Claude Code arguments):
  - `--local-fast` / `--local-quality` and `--local-vision` / `--local-no-vision` choose for one launch.
  - `CLAUDE_LOCAL_PROFILE=fast|quality` and `CLAUDE_LOCAL_VISION=on|off` do the same from the environment.
  - `--local-set-default` saves the options given with it to `~/.config/claude-local/defaults` (or `$XDG_CONFIG_HOME/claude-local/defaults` if you set that).
  - Precedence: option, then environment, then saved default, then built-in (fast, vision off).
  - One table in the script maps each combination to its oMLX model, measured context window, output cap and any model-specific Claude Code settings.
- **On each launch:**
  - Warns if OrbStack's VM, Ollama or LM Studio are holding memory.
  - Warns if a different model was used in the last 10 minutes, probably by another session, since this launch will swap it out.
  - Starts the oMLX server if it isn't running, in its own process group so Ctrl-C in Claude Code can't kill it.
  - Waits until the model is listed, and stops with a hint if the quality model isn't installed.
- **Images:** with vision off, oMLX silently drops images. So the wrapper adds a hook, for that session only, that refuses Claude Code's Read tool on `.png`, `.jpg`, `.jpeg`, `.gif` and `.webp` files, with a message telling the model to suggest `--local-vision`.
  - In testing, the model then stopped and told the user to relaunch.
  - Glob and Grep still see image files. Deny rules were tried first, but they also hid image files from those tools.
  - Pasted images can't be refused; the model simply won't see them.
- **Quality model only:** it sets `CLAUDE_CODE_MODEL_CAPABILITIES=-mid_conv_system` (undocumented), because Qwen3.8's chat template rejects system messages after the first one. It also caps output at 20K tokens so long reasoning can't push the cache past the window.
- **For the Claude Code process only (nothing global), it sets:**
  - the local endpoint and a dummy token;
  - every model tier mapped to the one local model;
  - the real context window (Claude Code assumes 200K for unknown models);
  - prompt-cache stability switches;
  - compatibility switches for a non-Anthropic backend;
  - single-slot limits and long timeouts.
- **Tools and MCP:** WebSearch (an Anthropic server-side tool) and LSP are disabled, and MCP servers are off (`--strict-mcp-config`). Pass `--mcp-config <file>` to add servers for one session.
- **Subcommands** such as `claude-local mcp list` or `claude-local doctor` pass straight through to Claude Code.

### 7. Size the context windows for this Mac

What remains of macOS's GPU memory budget after a model's weights decides how long a context fits. Read the budget with oMLX's bundled Python:

```sh
OMLX_RES=~/Applications/oMLX.app/Contents/Resources/Python
PYTHONHOME=$OMLX_RES/cpython-3.11 PYTHONPATH=$OMLX_RES/framework-mlx-base/lib/python3.11/site-packages \
  "$OMLX_RES/cpython-3.11/bin/python3" -c "import mlx.core as mx; i = mx.device_info(); \
  print('GPU budget:', round(i['max_recommended_working_set_size'] / 2**30, 1), 'GiB of', round(i['memory_size'] / 2**30), 'GiB')"
```

Measured on the tested Mac (28.1 GiB budget, `aggressive` guard). Each window was tested cold, on a freshly started server, with the largest prompt Claude Code sends at that window, which is the window minus about 23K tokens:

| Model | Vision | Weights loaded | Window (`row_ctx`) | Largest prompt tested | Time | Peak | Rejected from |
|---|---|---|---|---|---|---|---|
| fast | off | 19.7 GB | 131072 | 105.7K | 67 s | 26 GB | varies near 130K |
| fast | on | 20.8 GB | 106496 | 83.3K + image | 43 s | 26 GB | ~90K |
| quality | off | 15.2 GB | 94208 | 69.5K | 155 s | 26 GB | ~75K |
| quality | on | 17.5 GB | 81920 | 57.2K + image | 108 s | 26 GB | not reached |

The quality model's weights are smaller, but its attention cache is 3.2× larger per token (64 KiB against 20 KiB), so it fits less context. With the `balanced` guard, the fast model was rejected from ~78K.

For other Macs:

| GPU budget | `memory_guard_tier` | Windows | Status |
|---|---|---|---|
| ≥ 34 GiB (typically 48 GB Macs and up) | `balanced` or `aggressive` | the ones above, or larger | Expected to fit comfortably (not tested) |
| ~28 GiB (36 GB Macs) | `aggressive` | the ones above | **Tested** |
| < 27 GiB (32 GB Macs and below) | — | — | Not supported by this guide. Claude Code needs ≥ 64K of context, and there isn't room for it next to these models. |

- **Changing a window:** edit the `row_ctx=` value for that combination in the `profile_row` table in `~/.local/bin/claude-local` (or `src/claude-local` in the repo), or set `CLAUDE_LOCAL_CTX` for one launch. Keep `max_context_window` in `~/.omlx/model_settings.json` larger.
- **Output caps:** below a 20K output cap, Claude Code compacts at the window minus the cap minus 13K, so small windows need a small cap too (`CLAUDE_LOCAL_MAX_OUT`).
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

**c2. Vision check.** Draw a number and ask the vision model to read it. Expect `4821`. (Images need to be reasonably large: at 480×200 pixels the model got too few image tokens and read "481"; 640×400 and up worked.)

```sh
OMLX_RES=~/Applications/oMLX.app/Contents/Resources/Python
PYTHONHOME=$OMLX_RES/cpython-3.11 PYTHONPATH=$OMLX_RES/framework-mlx-base/lib/python3.11/site-packages \
  "$OMLX_RES/cpython-3.11/bin/python3" -c "from PIL import Image, ImageDraw, ImageFont
img = Image.new('RGB', (640, 400), 'white')
ImageDraw.Draw(img).text((200, 150), '4821', fill='black', font=ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial Bold.ttf', 72))
img.save('/tmp/claude-local-4821.png')"
printf '{"model":"qwen3.6-35b-a3b-vision","max_tokens":2000,"thinking":{"type":"adaptive"},"messages":[{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"%s"}},{"type":"text","text":"What number is written in this image? Reply with just the number."}]}]}' \
  "$(base64 -i /tmp/claude-local-4821.png | tr -d '\n')" > /tmp/claude-local-vision.json
curl -sS http://127.0.0.1:8765/v1/messages -H "Authorization: Bearer local" \
  -H "content-type: application/json" -H "anthropic-version: 2023-06-01" -d @/tmp/claude-local-vision.json \
  | /usr/bin/jq -r '.content[] | select(.type == "text") | .text'
```

**c3. Quality model check** (if installed). Expect "391"; the first request swaps models (a few seconds):

```sh
curl -sS http://127.0.0.1:8765/v1/messages -H "Authorization: Bearer local" \
  -H "content-type: application/json" -H "anthropic-version: 2023-06-01" \
  -d '{"model":"qwen3.8-27b","max_tokens":4000,"thinking":{"type":"adaptive"},
       "messages":[{"role":"user","content":"What is 17*23? Answer with just the number."}]}' \
  | /usr/bin/jq -r '.content[] | select(.type == "text") | .text'
```

**d. Claude Code in print mode.** Expect `OK` in a few seconds:

```sh
mkdir -p /tmp/claude-local-test && cd /tmp/claude-local-test
claude-local -p "Reply with exactly the word OK and nothing else."
```

**e. Agentic coding test.** This took 6 turns and about 30 s with the fast model on the tested Mac. To try the quality model, put `--local-quality` right after `claude-local`; it took 4 turns and about 60 s, most of it processing Claude Code's 16K-token prompt the first time.

```sh
rm -rf /tmp/claude-local-agentic && mkdir -p /tmp/claude-local-agentic && cd /tmp/claude-local-agentic && git init -q
claude-local -p "Create a Python module textstats.py with word_frequencies(text: str) -> dict[str, int] (lowercase, strip punctuation, count words) and top_n(text: str, n: int) -> list[tuple[str, int]] (sorted by count descending, then word ascending). Create test_textstats.py with unittest tests for an empty string, punctuation and ties. Run python3 -m unittest -v and fix failures until all pass. Finish with a one-line summary." \
  --permission-mode acceptEdits \
  --allowedTools "Read,Write,Edit,Glob,Grep,Bash(python3 -m unittest *),Bash(python3 -m unittest)"
python3 -m unittest -v 2>&1 | tail -3
```

The last command re-runs the tests yourself; expect `OK`.

**f. Interactive session.** First launch shows the theme picker, security notes and a folder-trust prompt, once per profile and folder:

```sh
cd /tmp/claude-local-test && claude-local
```

The header should read `qwen3.6-35b-a3b with medium effort`. In the session:
- Run `/context`. Expect about 16K of 131.1K tokens used, no MCP tools, and an auto-compact buffer of about 33K.
- Ask a question to confirm it answers.
- `/exit`.

**g. Memory acceptance test at full context.** This sends one prompt at the largest size Claude Code can send for a window, then reports the answer and the server's peak memory. Claude Code auto-compacts at the window minus about 33K and refuses to send more than the window minus about 23K, so the test uses about 108K tokens for the fast model's 131072 window.

The block below tests the fast model without vision. `./install-claude-local.sh --memory-test` runs the same test for every installed model and vision setting, each on a freshly started server; that's the easier way. By hand, set `CTX` and the `model` value to another row from step 7. The prompt starts with a unique line, so an earlier run's cache can't make the test look faster than it is.

```sh
CTX=131072
OMLX_RES=~/Applications/oMLX.app/Contents/Resources/Python
PYTHONHOME=$OMLX_RES/cpython-3.11 PYTHONPATH=$OMLX_RES/framework-mlx-base/lib/python3.11/site-packages \
  "$OMLX_RES/cpython-3.11/bin/python3" - "$CTX" > /tmp/claude-local-long.json <<'PY'
import glob, json, os, sys, sysconfig, time
target = int((int(sys.argv[1]) - 23000) * 3.8)   # Claude Code's largest prompt: window - 23K tokens, ~3.8 chars/token
text = f"RUN {time.time()}\n"   # unique start, so no earlier run's cache helps
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

- **Pass:** the answer matches the "expected answer" line and `phys_footprint_peak` stays below the GPU budget from step 7. The tested Mac took 67 s for 105.7K tokens and peaked at 26 GB.
- **Warm path:** run the `time curl` line again. It should answer in about a second from the prefix cache.
- **Fail:** if the result is an error mentioning "Prefill context too large", lower the context window (step 7) and re-run with the new `CTX`.

**h. Normal `claude` is unchanged.** Both commands should report no difference:

```sh
shasum -a 256 ~/.claude/settings.json ~/.claude/CLAUDE.md 2>/dev/null | diff - ~/claude-local-baseline/sha.txt && echo "settings unchanged"
claude auth status | diff - ~/claude-local-baseline/auth.txt && echo "login unchanged"
```

## Daily use

| Command | What it does |
|---|---|
| `claude-local` | Fast model, text only; takes the same flags as claude |
| `claude-local --local-vision` | Fast model with image input |
| `claude-local --local-quality` | Qwen3.8-27B, slower but stronger |
| `claude-local --local-quality --local-vision` | Qwen3.8-27B with image input |
| `claude-local -p "question"` | Print mode (wrapper options go first) |
| `claude-local --continue` | Resume the last local session in this folder |
| `claude-local --local-quality --local-set-default` | Make quality the default from now on |
| `claude-local --local-status` | Selection, server, installed models, memory warnings |
| `claude-local --local-start` | Load the selected model before you need it |
| `claude-local --local-stop` | Stop the server and free the model's memory now |
| `claude-local --local-help` | Show the wrapper's options |

Wrapper options (`--local-...`) always go before Claude Code's own arguments.

`CLAUDE_LOCAL_PROFILE=quality` and `CLAUDE_LOCAL_VISION=on` do the same as the options for one command or a whole shell. To go back to the built-in default, delete `~/.config/claude-local/defaults`.

Expect:
- **Fast model:** about 70–90 tokens/s generation, and about 1,500–1,900 tokens/s prefill on long prompts.
- **Quality model:** about 20–45 tokens/s generation with its multi-token-prediction head, and about 450–550 tokens/s prefill. A new session's first reply takes about 30–40 s while it processes Claude Code's 16K-token prompt; later turns come mostly from the cache.
- **Caching:** after the first turn, most of the prompt comes from the cache (about 98% hits in testing, for both models).
- **Switching models:** only one model is loaded at a time. The first request after a switch loads the other model (about 5–15 s), and the other model's cached prompts are kept on disk.
- **Memory:** for best results, close memory-heavy apps and stop VMs before long sessions.

Overrides for experiments: `CLAUDE_LOCAL_CTX`, `CLAUDE_LOCAL_MAX_OUT`, `CLAUDE_LOCAL_MODEL` (a served model name) and `CLAUDE_LOCAL_PORT`. For example: `CLAUDE_LOCAL_CTX=65536 CLAUDE_LOCAL_MAX_OUT=16384 claude-local`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `port 8765 is in use by pid N, which isn't oMLX` | Something else owns the port (`lsof -nP -iTCP:8765`). Stop it, or use another port: `CLAUDE_LOCAL_PORT=8766 claude-local`. |
| `oMLX did not list 'qwen3.6-35b-a3b' within 90 s` or `oMLX exited during startup` | Read `~/.omlx/logs/claude-local-server.log`. The model folder name under `~/.omlx/models/` must match the key in `model_settings.json`. |
| An API error mentioning "Prefill context too large" | The prompt didn't fit in GPU memory. Close large apps, stop VMs or other model servers, or lower the context window (step 7). |
| The model ignores the prompt or invents a task | Make sure you are on the oMLX backend (`--local-status`). The optional Ollama backend (`CLAUDE_LOCAL_BACKEND=ollama`) misbehaved this way on Ollama 0.30.10 and needs a newer Ollama. |
| Slow first reply in a new session | Claude Code's ~16K-token prompt is being processed cold: about 5–10 s with the fast model and 30–40 s with the quality model. Later turns reuse the SSD prefix cache. |
| `the quality model is not installed` | Run `./install-claude-local.sh --with-quality`. |
| The model says it can't see an image | Vision is off: relaunch with `--local-vision`. With vision off, image reads are refused and pasted images are dropped. |
| The vision model misreads small text | Small images get few image tokens: a 480×200 image lost a digit that 640×400 kept. Use full-size screenshots rather than tiny crops. |
| `oMLX is running but doesn't list '<model>'` | The server started before that model or its settings were installed. Run `claude-local --local-stop` (or re-run the installer with `--restart-server`); the next launch rescans the models. |
| Warning that a model "was used Ns ago, probably by another session" | Another `claude-local` window is using a different model. This launch swaps it out, and that window's next request swaps it back, each costing a reload. Use the same model in both, or accept the reloads. |
| Everything is slow, or the Mac is swapping | Another large memory user is running: OrbStack or Docker VMs, Ollama or LM Studio with a model loaded. `claude-local` warns about these at launch. |
| Claude Code updated and `claude-local` broke | Normal `claude` is unaffected. Run `claude-local -p "Reply OK"` and read the error. Check the environment variables in the wrapper against the new release's docs. |

## Updating

- **oMLX:** repeat step 2 with a new `OMLX_TAG`. Stop the server first with `claude-local --local-stop`. The config in `~/.omlx` is kept. Re-run steps 8b–8g.
- **Models:** to try another model, download it into a new folder under `~/.omlx/models/` and add an entry to `model_settings.json` with its own alias (not starting with `claude-`). Run it with `CLAUDE_LOCAL_MODEL=<alias> CLAUDE_LOCAL_CTX=<window> claude-local`, and measure its window first (step 8g); memory use changes with every model.
  - Making it a named choice like `--local-quality` takes several edits to `src/claude-local`: a row in `profile_row`, the option parsing, the `CLAUDE_LOCAL_PROFILE` and defaults checks, and the status loop.
  - Then run `python3 scripts/build.py`.
- **Claude Code:** it updates itself as usual. After a major update, re-run steps 8d and 8e.

## Uninstall

```sh
claude-local --local-stop
rm -f ~/.local/bin/claude-local
find ~/.local/bin -name 'claude-local.bak-*' -delete
rm -rf ~/.claude-local ~/.omlx ~/Applications/oMLX.app ~/Downloads/omlx ~/claude-local-baseline
rm -rf "${XDG_CONFIG_HOME:-$HOME/.config}/claude-local"
```

If oMLX was already set up on the Mac before `claude-local`, don't delete `~/.omlx`. Remove the model folder you don't want, then restore the originals from `~/.omlx/*.pre-claude-local`.

## Design notes

- **Why this model:** Qwen3.6-35B-A3B is a mixture-of-experts model with 3B active parameters, so it runs at about 80+ tokens/s on a 32-core M5 Max. Only 10 of its 40 layers keep a normal attention cache (about 20 KiB per token), so long contexts are cheap.
- **The quality model:** Qwen3.8-27B (August 2026) is a dense 27B model. Its vendor benchmarks are well ahead of Qwen3.6-35B-A3B (SWE-bench Pro 61.7 against 49.5), but nobody has reproduced them independently, and they were run at full precision with a 256K context. Here it's a 4-bit build at up to a 92K window, and it generates about 2–4× slower and processes prompts about 3–4× slower. On the one coding test run here, both models passed. The build is `oQ4e-mtp` from oMLX's author, one of the few 4-bit MLX builds that keep the model's multi-token-prediction head.
- **Vision:** both models accept images. oMLX's text engine silently drops images, and its vision engine costs 1.1–2.3 GB more memory. A symlinked second folder is the way to give the same weights two engine settings, because oMLX ties the engine choice to the model's folder.
- **Why the Unsloth build:** its dynamic 4-bit quantization measures about 3× closer to the full-precision model than uniform 4-bit (KL divergence 0.029 vs 0.088), for about 1 GB more. 5-bit and larger don't leave room for context on a 36 GB Mac.
- **Why oMLX:** it serves the Anthropic Messages API natively. It removes Claude Code's cache-breaking per-request markers, accepts mid-conversation system messages and adaptive thinking, and has a paged prefix cache on SSD. Version 0.7.0rc1 or later is needed for the bounded long-prompt attention path and the partial-block cache reuse for this model family.
- **Why not 32K context:** Claude Code auto-compacts at the window minus about 33K, which a 32K window is already below.
