# Installing `claude-local` on a Mac

These steps set up `claude-local`, a second command that runs Claude Code against a local open-weight model served on the Mac itself. The normal `claude` command, its login, settings and history are left untouched. Nothing here needs admin rights.

Tested on September 28, 2026 with:

| Component | Version |
|---|---|
| Macs | MacBook Pro, Apple M5 Max (32-core GPU), 36 GB, macOS 27.0; Mac Studio, Apple M3 Ultra (80-core GPU), 96 GB, macOS 27.0 |
| Claude Code | 2.1.283, native installer (`~/.local/bin/claude`) |
| Inference server | oMLX 0.7.0rc1 (`oMLX-0.7.0rc1-macos26-27.dmg`) |

What you end up with:

| Piece | Location |
|---|---|
| Wrapper command | `~/.local/bin/claude-local` |
| Claude Code profile for local sessions | `~/.claude-local/` (its own settings, history, sessions and Keychain entry) |
| Inference server app | `~/Applications/oMLX.app`, run headless by the wrapper on `127.0.0.1:8765` |
| Server config, models, cache, logs | `~/.omlx/` |
| Saved model and vision defaults | `~/.config/claude-local/defaults` (or `$XDG_CONFIG_HOME/claude-local/defaults` if you set that), only if you save one |
| Context windows measured on this Mac | `~/.config/claude-local/windows`, only where `--memory-test` found a different window from the built-in one |

The models depend on how much memory the Mac has. Each launch picks one of up to three models, and whether image input (vision) is on:

| Mac (memory class) | fast | quality | laguna | Default |
|---|---|---|---|---|
| 16–35 GB, e.g. MacBook Air M2 16 GB | `craquehouse/Qwen3.5-9B-oQ4e-fp16-text-only` (5.3 GB), text only | — | — (no Laguna fits) | fast |
| 36–95 GB, e.g. MacBook Pro M5 Max 36 GB | `unsloth/Qwen3.6-35B-A3B-UD-MLX-4bit` (21.7 GB) | `Jundot/Qwen3.8-27B-oQ4e-mtp` (17.0 GB) | `mlx-coders/Laguna-XS-2.1-oQ4e` (19.5 GB), text only | fast |
| 96 GB and up, e.g. Mac Studio M3 Ultra 96 GB or M4 Max 128 GB | `Jundot/Qwen3.6-35B-A3B-oQ6-mtp` (30.2 GB) | `Jundot/Qwen3.8-27B-oQ6e-mtp` (23.7 GB) | `mlx-community/Laguna-S-2.1-oQ4e-fast` (63.3 GB), text only | laguna |

Step 7 lists the context window of every combination. `claude-local --local-status` shows the Mac's own, installed or not.

| Choice | Command |
|---|---|
| This Mac's default model, text only | `claude-local` |
| A specific model | `claude-local --local-fast`, `--local-quality` or `--local-laguna` |
| With image input (Qwen models) | add `--local-vision`, e.g. `claude-local --local-fast --local-vision` |

On the MacBooks only one model fits in memory at a time; on the Studios the two Qwen models fit together, but Laguna S needs the memory to itself. Switching takes from about 5 s (the Qwen models) to about 30 s (Laguna S) the first time.

> **Privacy note.** Inference is local, but any organization-managed Claude Code settings still apply to `claude-local`: hooks, telemetry and so on, under `/Library/Application Support/ClaudeCode/managed-settings.json`. On a managed Mac, prompts and tool events may still leave the machine exactly as they do with normal `claude`. Nothing in this guide bypasses managed settings. Never "fix" this with `--bare` or `CLAUDE_CODE_SIMPLE`.

## Quick install with the script

`install-claude-local.sh` sits next to this file and automates every step below. Copy it to the Mac and run it:

```sh
chmod +x install-claude-local.sh
./install-claude-local.sh
```

| Command | What it does |
|---|---|
| `./install-claude-local.sh` | The fast model and this Mac's default (Laguna on 96 GB and up), then the quick checks (a few minutes after downloads) |
| `./install-claude-local.sh --with-quality` | Also the quality model (17–24 GB more); safe to add later |
| `./install-claude-local.sh --with-laguna` | Also Laguna on a 36 GB Mac (20 GB more) |
| `./install-claude-local.sh --with-all` | Every model this Mac can run |
| `./install-claude-local.sh --memory-test` | Also test every installed model and vision setting at its full window, stepping down until one fits, and record the result (step 7) |
| `./install-claude-local.sh --no-verify` | Install only |
| `./install-claude-local.sh --restart-server` | Restart the server to load new models even if it looks busy |

What the script does:
- Checks the Mac first. It stops if the Mac has less than 16 GB of memory unless you pass `--force`.
- Picks the models for the Mac's memory class, from the same table the wrapper uses (`claude-local --local-status`).
- Restarts the server only when it has new models or settings and no session seems to be using it. A request in flight, one in the last 10 minutes, or a status it can't read counts as in use; `--restart-server` overrides this.
- Downloads models pinned to exact Hugging Face revisions, four files at a time (Hugging Face limits the speed of each connection), and checks every file's size. It skips Python files, which are model code for other runtimes. New downloads land in `~/.omlx/downloads` and move into `~/.omlx/models` only when complete.
- Sets up the vision variants (symlinks, no extra disk).
- For Laguna XS 2.1, replaces the model's chat template with Poolside's Laguna S 2.1 template (step 3).
- Verifies the oMLX download's SHA-256 and Apple's signature and notarization.
- Reads the Mac's GPU budget and warns if it is lower than usual for its class.
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
- at least 16 GB of memory (see step 7 for what each size runs);
- the GPU core count;
- macOS 26 or 27 (macOS 15 also works, but gives a 16 GB Mac about 1.2 GB less GPU memory; see step 2);
- the Claude Code native install;
- a `jq` version, since `jq` ships with macOS 15 and later;
- enough free disk for the models (step 3) plus room for the prompt cache: 20 GB on 16 GB Macs, 50 GB on 36 GB, 300 GB on 96 GB and up;
- port 8765 free.

> **Pasting into zsh:** the blocks in this guide have no `#` comments, because zsh doesn't treat `#` as a comment when you paste unless `setopt interactivecomments` is on. Explanations are in the text around each block.

Requirements:
- **Apple Silicon with at least 16 GB of memory.** The memory decides the models:
  - 16–35 GB Macs get a small Qwen model;
  - 36–95 GB Macs get the three models the MacBook Pro was tested with;
  - Macs with 96 GB or more get higher-precision Qwen builds and Laguna S.
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

This defines a small download function, `get_model <repo> <revision> <folder>`. Every model is pinned to the exact Hugging Face revision that was tested. Python files in a repository are skipped: they are model code for other runtimes, which oMLX never runs, and web proxies may block them. Don't start the server until the downloads finish.

```sh
get_model() {
  local repo=$1 rev=$2 dest=~/.omlx/models/$3
  mkdir -p "$dest"
  curl -fsSL "https://huggingface.co/api/models/$repo/tree/$rev?recursive=true" \
    | /usr/bin/jq -r '.[] | select(.type == "file" and .path != ".gitattributes" and (.path | endswith(".py") | not)) | "\(.path) \(.lfs.size // .size)"' \
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

```

Then run the lines for your Mac's memory class. The fast model is required, and on 96 GB and up so is Laguna, the default there; the others are optional.

**16–35 GB** (fast, 5.3 GB):

```sh
get_model craquehouse/Qwen3.5-9B-oQ4e-fp16-text-only 61b16465e2c70e58995a79a25fc40216a37984c0 Qwen3.5-9B-oQ4e-fp16-text-only
```

**36–95 GB** (fast 21.7 GB; quality 17.0 GB; Laguna XS 19.5 GB):

```sh
get_model unsloth/Qwen3.6-35B-A3B-UD-MLX-4bit 6700c3e5bdeb050a379c8d2a4133f43f3647f20f Qwen3.6-35B-A3B-UD-MLX-4bit
get_model Jundot/Qwen3.8-27B-oQ4e-mtp 04dc5509edd8670fc78cc8c2f74bf9b77b1f2acc Qwen3.8-27B-oQ4e-mtp
get_model mlx-coders/Laguna-XS-2.1-oQ4e 2cdec8e0a0e3ce1562c92767c394bb952835ee11 Laguna-XS-2.1-oQ4e
```

**96 GB and up** (fast 30.2 GB; quality 23.7 GB; Laguna S 63.3 GB):

```sh
get_model Jundot/Qwen3.6-35B-A3B-oQ6-mtp 276df7cc7b6face3d66d635bb841248c51ec3e8d Qwen3.6-35B-A3B-oQ6-mtp
get_model Jundot/Qwen3.8-27B-oQ6e-mtp f7ec1f012451c7a76e775e2fdefdd5f0a51f11f7 Qwen3.8-27B-oQ6e-mtp
get_model mlx-community/Laguna-S-2.1-oQ4e-fast 871f699b0e8852ee2ab74fb1e67767bdcc6358ee Laguna-S-2.1-oQ4e-fast
```

Every line must say `OK`. If any say `FAIL`, run that `get_model` line again; it resumes where it stopped.

**Laguna XS only:** replace its chat template with Poolside's Laguna S 2.1 template. It is the same format plus a `preserve_thinking` flag, which makes oMLX pass earlier thinking back correctly; without it the conversation history renders with two think blocks. The second line must print `OK`:

```sh
curl -fsSL -o ~/.omlx/models/Laguna-XS-2.1-oQ4e/chat_template.jinja https://huggingface.co/poolside/Laguna-S-2.1/resolve/0f573140834b11cfac0c2af97a101a7a69a13e22/chat_template.jinja
echo "444819b8ad4612870827ac05b9147fe9e3344d3850cae8c2790898fc514099ff  $HOME/.omlx/models/Laguna-XS-2.1-oQ4e/chat_template.jinja" | shasum -a 256 -c -
```

Re-running `get_model` for Laguna XS restores its original template, so repeat this afterwards.

Then create the vision variants of the Qwen models you downloaded (Laguna has none). Each is a symlink to the same weights under a second folder name, which oMLX treats as a separate model and serves with its vision engine:

```sh
cd ~/.omlx/models
for m in Qwen3.6-35B-A3B-UD-MLX-4bit Qwen3.8-27B-oQ4e-mtp Qwen3.6-35B-A3B-oQ6-mtp Qwen3.8-27B-oQ6e-mtp; do [ -d "$m" ] && ln -sfn "$m" "$m-vision"; done
cd ~
```

The 16 GB model is a text-only build, so it has no vision variant.

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
}
EOF
```

What these settings do:

| Setting | Why |
|---|---|
| `host` 127.0.0.1, `port` 8765 | Local only. Port 8765 avoids the common dev-server port 8000. |
| `max_concurrent_requests` 1 | One generation at a time. Parallel requests would each need their own KV cache and would evict the prefix cache. oMLX's default is 8. |
| `ssd_cache_max_size` 50GB | The prefix cache lives on the SSD. The default would take about half the free disk. Use `20GB` on a 16 GB Mac and `300GB` on 96 GB and up, where Laguna's cache snapshots take more room. |
| `memory_guard_tier` aggressive | Lets a prompt use up to 95% of the GPU budget instead of 90%. Needed for the context windows in step 7 on every class of Mac. |
| `model_type_override` llm / vlm | `llm` loads a model text-only, skipping its vision tower (the fast model then takes 19.7 GB instead of 20.8 GB). The `-vision` entries use `vlm`, oMLX's vision engine. |
| `model_alias` | The names Claude Code uses, for example `qwen3.6-35b-a3b`, `qwen3.8-27b-oq6-vision` or `laguna-s-2.1`. They must **not** start with `claude-`, or Claude Code ignores its context-window override. |
| `max_context_window` 81920–262144 | The server-side limit, per model. It is larger than any window Claude Code is given, so tokenizer differences never cause rejections; the memory guard is what really limits context. |
| Fast sampling 0.6 / 0.95 / 20 / 0 / 0 | Qwen's recommended "thinking mode, precise coding" settings for Qwen3.6. Claude Code sends no temperature while thinking is on, so these apply. |
| Quality sampling 1.0 / 0.95 / 20 / 0 / 0 | Qwen's recommended thinking-mode settings for Qwen3.8, which its benchmarks used. |
| Quality `reasoning_effort` medium | Qwen3.8 defaults to `xhigh`, which can think for minutes on hard prompts at this model's speed. On a test coding task `xhigh` took 73 s against 57 s for `medium`, with the same result. Set it to `xhigh` here if you want Qwen's default. Claude Code's `/effort` setting doesn't reach it. |
| Quality `mtp_enabled` true (text only) | Qwen3.8's multi-token-prediction head drafts about 3.6 tokens per step (88–97% accepted). It's left off for the vision variant until that's been verified. |
| `enable_thinking`, `preserve_thinking` true | Keeps reasoning across turns, which Qwen and Poolside recommend for agents and which keeps the prompt prefix stable for caching. The Qwen3.5-9B template has no `preserve_thinking` flag, so its entry leaves it out. |
| Laguna sampling 1.0 / 1.0 / 20 / 0 | Poolside's recommended settings (temperature, top_p, top_k, min_p), which its benchmarks used. Laguna has no effort setting. |
| 6-bit `mtp_enabled` true (text only) | The Studios' Qwen builds keep their multi-token-prediction heads, which makes the 6-bit fast model about as fast as a plain 4-bit one at long context. |
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
chmod +x ~/.local/bin/claude-local
bash -n ~/.local/bin/claude-local && echo "syntax OK"
claude-local --local-status
```

What the wrapper does:

- **Model and vision selection** (wrapper options must come before any Claude Code arguments):
  - `--local-fast` / `--local-quality` / `--local-laguna` and `--local-vision` / `--local-no-vision` choose for one launch.
  - `CLAUDE_LOCAL_PROFILE=fast|quality|laguna` and `CLAUDE_LOCAL_VISION=on|off` do the same from the environment.
  - `--local-set-default` saves the options given with it to `~/.config/claude-local/defaults` (or `$XDG_CONFIG_HOME/claude-local/defaults` if you set that).
  - Precedence: option, then environment, then saved default, then built-in (fast, or laguna on 96 GB and up; vision off).
  - A model without image input (Laguna, and the 16 GB Mac's model): `--local-vision` is an error, and a saved or environment `vision=on` is set aside for that session with a warning.
  - One table in the script, `catalog`, maps each memory class and model to its Hugging Face revision, oMLX folder, context windows, output cap and any model-specific Claude Code settings. The class comes from the Mac's memory size (`CLAUDE_LOCAL_MACHINE=16|36|96|128` overrides it).
  - A window measured on this Mac by `install-claude-local.sh --memory-test` (in `~/.config/claude-local/windows`) wins over the built-in one; `CLAUDE_LOCAL_CTX` wins over both.
- **On each launch:**
  - Warns if Ollama or LM Studio are holding memory, and on 16 and 36 GB Macs if OrbStack's VM is running.
  - Warns if a different model was used in the last 10 minutes, probably by another session, since this launch will swap it out.
  - Starts the oMLX server if it isn't running, in its own process group so Ctrl-C in Claude Code can't kill it.
  - Waits until the model is listed, and stops with a hint if the chosen model isn't installed or doesn't fit this Mac.
- **Images:** with vision off, oMLX silently drops images. So the wrapper adds a hook, for that session only, that refuses Claude Code's Read tool on `.png`, `.jpg`, `.jpeg`, `.gif` and `.webp` files, with a message telling the model to suggest `--local-vision`.
  - In testing, the model then stopped and told the user to relaunch.
  - Glob and Grep still see image files. Deny rules were tried first, but they also hid image files from those tools.
  - Pasted images can't be refused; the model simply won't see them.
- **Mid-conversation system messages:** for every model except the 36 GB Mac's fast model, it sets `CLAUDE_CODE_MODEL_CAPABILITIES=-mid_conv_system` (undocumented). Those models' chat templates reject system messages after the first one, and oMLX's fallback moves them, which breaks the prompt cache.
- **Output caps:** 32K tokens, 20K for the quality model so long reasoning can't push the cache past the window, and 8K on 16 GB Macs.
- **Lean mode (16 GB Macs):** it adds `--tools=Read,Edit,Write,Bash,Grep,Glob --disable-slash-commands`, which cuts Claude Code's prompt from about 16K tokens to about 4.5K. `CLAUDE_LOCAL_LEAN=on|off` overrides the default.
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

Budgets by memory size (macOS 26 and 27; oMLX's `aggressive` guard admits a request up to 95% of it):

| Memory | GPU budget | Source |
|---|---|---|
| 16 GB | 11.8 GiB (10.7 GiB on macOS 15) | Reported by others, not measured here |
| 36 GB | 28.1 GiB | Measured |
| 96 GB | 77.8 GiB | Measured |
| 128 GB | 96–107.5 GiB (reports differ) | Reported by others, not measured here |

Each window below was tested cold, on a freshly started server, with the largest prompt Claude Code sends at that window: the window minus the output cap (at most 20K) minus 3K, so about 23K below the window, or 11K with the 16 GB Macs' 8K cap.

**36 GB (MacBook Pro M5 Max, 28.1 GiB budget), measured:**

| Model | Vision | Weights loaded | Window | Largest prompt tested | Time | Peak | Rejected from |
|---|---|---|---|---|---|---|---|
| fast | off | 19.7 GB | 131072 | 105.7K | 67 s | 26 GB | varies near 130K |
| fast | on | 20.8 GB | 106496 | 83.3K + image | 43 s | 26 GB | ~90K |
| quality | off | 15.2 GB | 94208 | 69.5K | 155 s | 26 GB | ~75K |
| quality | on | 17.5 GB | 81920 | 57.2K + image | 108 s | 26 GB | not reached |
| laguna (XS) | off | 18.7 GB | 114688 | 89.3K | 69 s | 26 GB | 122880 |

The quality model's weights are smaller, but its attention cache is 3.2× larger per token (64 KiB against 20 KiB), so it fits less context. Laguna XS's cache is 40 KiB per token. With the `balanced` guard, the fast model was rejected from ~78K.

**96 GB (Mac Studio M3 Ultra, 77.8 GiB budget), measured:**

| Model | Vision | Weights on disk | Window | Largest prompt tested | Time | Peak | Rejected from |
|---|---|---|---|---|---|---|---|
| fast (Qwen3.6, 6-bit) | off | 30.2 GB | 262144 | 223.7K | 297 s | 43 GB | not reached (the model's maximum) |
| fast (Qwen3.6, 6-bit) | on | 30.2 GB | 262144 | 223.9K + image | 273 s | 44 GB | not reached |
| quality (Qwen3.8, 6-bit) | off | 23.7 GB | 131072 | 104.3K | 343 s | 43 GB | not tested; memory allows more |
| quality (Qwen3.8, 6-bit) | on | 23.7 GB | 131072 | 104.6K + image | 335 s | 44 GB | not tested |
| laguna (S 2.1) | off | 63.3 GB | 131072 | 103.8K | 204 s | 70 GB | 163840 |

- **Laguna S:** a 147456 window also passed, a 119.2K prompt in 249 s peaking at 72 GB. That is close to the guard's 73.9 GiB limit, so the built-in window stays at 131072 to leave room for other apps. To use the larger one when the Studio is otherwise idle, put `laguna-s-2.1=147456` in `~/.config/claude-local/windows`.
- **Quality model:** memory would allow a larger window, but a cold 104K prompt already takes almost 6 minutes.

**16 GB and 128 GB: estimates, not yet measured.**

| Memory | fast | quality | laguna |
|---|---|---|---|
| 16 GB | 65536 (49152 on macOS 15), text only | — | — |
| 128 GB | 262144, vision 262144 | 131072, vision 131072 | 196608 |

On those Macs, run `./install-claude-local.sh --memory-test` once. For each installed model and vision setting it:
- tests the built-in window;
- steps down 8K or 16K at a time until a window passes;
- records the result in `~/.config/claude-local/windows`, which `claude-local --local-status` then marks "(this Mac)".

A few things to know:
- **Large windows and cold prompts:** on the Studios, memory allows larger windows still, but a cold prompt that long takes many minutes to process (a 128K prompt takes about 5 minutes on the M3 Ultra with Laguna, and 9 on an M4 Max). So the windows above favor responsiveness.
- **16 GB Macs:** oMLX 0.7.0rc1's memory guard sometimes rejects prompts on 16 GB Macs that would fit. A fix is merged but not yet released (oMLX PR #3933). If `--memory-test` or a session is rejected well below the window, update oMLX when a newer release is out, then re-run the test.

- **Changing a window:** put `<alias>=<window>` in `~/.config/claude-local/windows` (the aliases are listed by `claude-local --local-status`), or set `CLAUDE_LOCAL_CTX` for one launch. Keep `max_context_window` in `~/.omlx/model_settings.json` larger.
- **Output caps:** below a 20K output cap, Claude Code compacts at the window minus the cap minus 13K, so small windows need a small cap too (`CLAUDE_LOCAL_MAX_OUT`).
- **Not below 65536** (49152 in lean mode, with an 8K output cap): Claude Code's own prompt and tools take about 16K tokens (4.5K in lean mode), and it reserves the output cap plus about 13K before auto-compacting.
- **Don't raise the budget:** don't raise `iogpu.wired_limit_mb` with sudo to work around this. It affects the whole system and needs admin rights.

### 8. Verify

Stop OrbStack or other large memory users first if they're running (`orbctl stop`).

**a. Start the server and load the model** (10 s to a minute the first time), and note this Mac's model names:

```sh
claude-local --local-fast --local-start
claude-local --local-status
FAST=$(claude-local --local-fast --local-status | awk '/^model:/ { print $NF }')
echo "$FAST"
```

The checks below use `$FAST`. For another model, set it the same way with `--local-quality` or `--local-laguna`.

**b. Raw API check.** Expect a thinking block, then the text "391":

```sh
curl -sS http://127.0.0.1:8765/v1/messages -H "Authorization: Bearer local" \
  -H "content-type: application/json" -H "anthropic-version: 2023-06-01" \
  -d '{"model":"'"$FAST"'","max_tokens":2000,"thinking":{"type":"adaptive"},
       "messages":[{"role":"user","content":"What is 17*23? Answer with just the number."}]}' \
  | /usr/bin/jq '{stop_reason, usage, content: [.content[] | {type, text: ((.text // .thinking)[0:120])}]}'
```

**c. Tool-call check.** Expect `"stop_reason": "tool_use"` and a `Bash` call with `ls /tmp`:

```sh
curl -sS http://127.0.0.1:8765/v1/messages -H "Authorization: Bearer local" \
  -H "content-type: application/json" -H "anthropic-version: 2023-06-01" \
  -d '{"model":"'"$FAST"'","max_tokens":4000,"thinking":{"type":"adaptive"},
       "tools":[{"name":"Bash","description":"Run a shell command.","input_schema":{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}}],
       "messages":[{"role":"user","content":"List the files in /tmp using the Bash tool."}]}' \
  | /usr/bin/jq '{stop_reason, calls: [.content[] | select(.type == "tool_use") | {name, input}]}'
```

**c2. Vision check** (not on 16 GB Macs, whose model is text only). Draw a number and ask the vision model to read it. Expect `4821`. (Images need to be reasonably large: at 480×200 pixels the model got too few image tokens and read "481"; 640×400 and up worked.)

```sh
OMLX_RES=~/Applications/oMLX.app/Contents/Resources/Python
PYTHONHOME=$OMLX_RES/cpython-3.11 PYTHONPATH=$OMLX_RES/framework-mlx-base/lib/python3.11/site-packages \
  "$OMLX_RES/cpython-3.11/bin/python3" -c "from PIL import Image, ImageDraw, ImageFont
img = Image.new('RGB', (640, 400), 'white')
ImageDraw.Draw(img).text((200, 150), '4821', fill='black', font=ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial Bold.ttf', 72))
img.save('/tmp/claude-local-4821.png')"
printf '{"model":"%s-vision","max_tokens":2000,"thinking":{"type":"adaptive"},"messages":[{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"%s"}},{"type":"text","text":"What number is written in this image? Reply with just the number."}]}]}' \
  "$FAST" "$(base64 -i /tmp/claude-local-4821.png | tr -d '\n')" > /tmp/claude-local-vision.json
curl -sS http://127.0.0.1:8765/v1/messages -H "Authorization: Bearer local" \
  -H "content-type: application/json" -H "anthropic-version: 2023-06-01" -d @/tmp/claude-local-vision.json \
  | /usr/bin/jq -r '.content[] | select(.type == "text") | .text'
```

**c3. Quality and Laguna checks** (if installed). Expect "391" from each; the first request swaps models (seconds for the quality model, about 30 s for Laguna S):

```sh
for p in quality laguna; do
  M=$(claude-local --local-$p --local-status | awk '/^model:/ { print $NF }')
  echo "$p: $M"
  curl -sS http://127.0.0.1:8765/v1/messages -H "Authorization: Bearer local" \
    -H "content-type: application/json" -H "anthropic-version: 2023-06-01" \
    -d '{"model":"'"$M"'","max_tokens":8000,"thinking":{"type":"adaptive"},
         "messages":[{"role":"user","content":"What is 17*23? Answer with just the number."}]}' \
    | /usr/bin/jq -r '[.content[]? | select(.type == "text") | .text] | join("") // .error.message'
done
```

A model that isn't installed or doesn't fit this Mac prints an error instead.

**d. Claude Code in print mode.** Expect `OK` in a few seconds:

```sh
mkdir -p /tmp/claude-local-test && cd /tmp/claude-local-test
claude-local -p "Reply with exactly the word OK and nothing else."
```

**e. Agentic coding test.** This runs this Mac's default model. To try another, put `--local-fast`, `--local-quality` or `--local-laguna` right after `claude-local`. On the MacBook Pro:
- the fast model took 6 turns and about 30 s;
- the quality model took 4 turns and about 60 s, most of it processing Claude Code's 16K-token prompt the first time;
- Laguna XS took 4 turns and about 25 s.

On the Mac Studio, Laguna S took 4 turns and about 55 s, the fast model 6 turns and about 35 s, and the quality model 4 turns and about 60 s.

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

The header should show this Mac's default model, for example `qwen3.6-35b-a3b with medium effort` on a 36 GB Mac. In the session:
- Run `/context`. Expect about 16K tokens used (about 4.5K in lean mode), the model's window as the total, no MCP tools, and an auto-compact buffer of about 33K.
- Ask a question to confirm it answers.
- `/exit`.

**g. Memory acceptance test at full context.** This sends one prompt at the largest size Claude Code can send for a window, then reports the answer and the server's peak memory. Claude Code auto-compacts at the window minus about 33K and refuses to send more than the window minus about 23K, so the test uses about 108K tokens for a 131072 window.

`./install-claude-local.sh --memory-test` runs this test for every installed model and vision setting, each on a freshly started server. It also measures each model's characters per token and steps the window down until one fits; that's the easier way.

By hand, the block below tests the fast model without vision:
- Set `CTX` to its window from `claude-local --local-status`.
- The characters-per-token figure (3.8) suits the Qwen tokenizers; `count_tokens` shows the real count.
- The prompt starts with a unique line, so an earlier run's cache can't make the test look faster than it is.

```sh
CTX=131072
OMLX_RES=~/Applications/oMLX.app/Contents/Resources/Python
PYTHONHOME=$OMLX_RES/cpython-3.11 PYTHONPATH=$OMLX_RES/framework-mlx-base/lib/python3.11/site-packages \
  "$OMLX_RES/cpython-3.11/bin/python3" - "$CTX" "$FAST" > /tmp/claude-local-long.json <<'PY'
import glob, json, os, sys, sysconfig, time
target = int((int(sys.argv[1]) - 23000) * 3.8)   # Claude Code's largest prompt: window - 23K tokens, ~3.8 chars/token
text = f"RUN {time.time()}\n"   # unique start, so no earlier run's cache helps
for f in sorted(glob.glob(os.path.join(sysconfig.get_paths()["stdlib"], "**", "*.py"), recursive=True)):
    text += f"\n##### FILE: {os.path.basename(f)}\n" + open(f, encoding="utf-8", errors="replace").read()
    if len(text) >= target:
        break
text = text[:target]
last = text[text.rindex("##### FILE: ") + 12:].split("\n", 1)[0]
q = "\n\nQuestion: What is the file name in the very last '##### FILE:' header above? Reply with only the file name."
print(json.dumps({"model": sys.argv[2], "max_tokens": 200, "thinking": {"type": "disabled"},
                  "messages": [{"role": "user", "content": text + q}]}))
print(f"expected answer: {last}", file=sys.stderr)
PY
H=(-H "Authorization: Bearer local" -H "content-type: application/json" -H "anthropic-version: 2023-06-01")
curl -sS "${H[@]}" http://127.0.0.1:8765/v1/messages/count_tokens -d @/tmp/claude-local-long.json; echo
time curl -sS -m 2400 "${H[@]}" http://127.0.0.1:8765/v1/messages -d @/tmp/claude-local-long.json \
  | /usr/bin/jq '{stop_reason, answer: .content[0].text, usage, error}'
footprint -p "$(cat ~/.omlx/claude-local-server.pid)" | grep phys_footprint
```

- **Pass:** the answer matches the "expected answer" line and `phys_footprint_peak` stays below the GPU budget from step 7. The MacBook Pro took 67 s for 105.7K tokens and peaked at 26 GB.
- **Warm path:** run the `time curl` line again. It should answer in about a second from the prefix cache.
- **Fail:** if the result is an error mentioning "Prefill context too large" or "Prefill would require", lower the context window (step 7) and re-run with the new `CTX`.

**h. Normal `claude` is unchanged.** Both commands should report no difference:

```sh
shasum -a 256 ~/.claude/settings.json ~/.claude/CLAUDE.md 2>/dev/null | diff - ~/claude-local-baseline/sha.txt && echo "settings unchanged"
claude auth status | diff - ~/claude-local-baseline/auth.txt && echo "login unchanged"
```

## Daily use

| Command | What it does |
|---|---|
| `claude-local` | This Mac's default model, text only; takes the same flags as claude |
| `claude-local --local-fast` | The fast model (Qwen) |
| `claude-local --local-fast --local-vision` | The fast model with image input |
| `claude-local --local-quality` | Qwen3.8-27B, slower but stronger |
| `claude-local --local-quality --local-vision` | Qwen3.8-27B with image input |
| `claude-local --local-laguna` | Laguna (text only) |
| `claude-local -p "question"` | Print mode (wrapper options go first) |
| `claude-local --continue` | Resume the last local session in this folder |
| `claude-local --local-quality --local-set-default` | Make quality the default from now on |
| `claude-local --local-status` | This Mac's models and windows, the selection, the server, memory warnings |
| `claude-local --local-start` | Load the selected model before you need it |
| `claude-local --local-stop` | Stop the server and free the model's memory now |
| `claude-local --local-help` | Show the wrapper's options |

Wrapper options (`--local-...`) always go before Claude Code's own arguments.

`CLAUDE_LOCAL_PROFILE=quality` (or `fast`, `laguna`) and `CLAUDE_LOCAL_VISION=on` do the same as the options for one command or a whole shell. To go back to the built-in default, delete `~/.config/claude-local/defaults`.

Expect, on the MacBook Pro:
- **Fast model:** about 70–90 tokens/s generation, and about 1,500–1,900 tokens/s prefill on long prompts.
- **Quality model:** about 20–45 tokens/s generation with its multi-token-prediction head, and about 450–550 tokens/s prefill. A new session's first reply takes about 30–40 s while it processes Claude Code's 16K-token prompt; later turns come mostly from the cache.
- **Laguna XS:** about 80–100 tokens/s generation, and about 1,300–1,400 tokens/s prefill on long prompts.

On the Mac Studio (M3 Ultra, 80-core GPU), measured writing code at short context:
- **Laguna S:** about 65 tokens/s generation and about 500 tokens/s prefill on long prompts.
- **Fast model:** about 185 tokens/s and 750 tokens/s.
- **Quality model:** about 75 tokens/s and 300 tokens/s.

The vision variants generate more slowly, because they don't use the multi-token-prediction heads.

On a 16 GB M2 (estimates from others' measurements): about 16–18 tokens/s generation and 150 tokens/s prefill, so a new session's first reply takes about 30 s in lean mode.
- **Caching:** after the first turn, most of the prompt comes from the cache (about 98% hits in testing, for both models).
- **Switching models:** on the MacBooks only one model is loaded at a time; on the Studios the two Qwen models can stay loaded together. The first request after a switch loads the other model (about 5–15 s; about 30 s for Laguna S), and the other model's cached prompts are kept on disk.
- **Memory:** for best results, close memory-heavy apps and stop VMs before long sessions.

Overrides for experiments: `CLAUDE_LOCAL_CTX`, `CLAUDE_LOCAL_MAX_OUT`, `CLAUDE_LOCAL_MODEL` (a served model name), `CLAUDE_LOCAL_PORT`, `CLAUDE_LOCAL_LEAN=on|off` and `CLAUDE_LOCAL_MACHINE=16|36|96|128`. For example: `CLAUDE_LOCAL_CTX=65536 CLAUDE_LOCAL_MAX_OUT=16384 claude-local`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `port 8765 is in use by pid N, which isn't oMLX` | Something else owns the port (`lsof -nP -iTCP:8765`). Stop it, or use another port: `CLAUDE_LOCAL_PORT=8766 claude-local`. |
| `oMLX did not list 'qwen3.6-35b-a3b' within 90 s` or `oMLX exited during startup` | Read `~/.omlx/logs/claude-local-server.log`. The model folder name under `~/.omlx/models/` must match the key in `model_settings.json`. |
| An API error mentioning "Prefill context too large" or "Prefill would require" | The prompt didn't fit in GPU memory. Close large apps, stop VMs or other model servers, or lower the context window (step 7). On a 16 GB Mac this can also be oMLX 0.7.0rc1's over-cautious guard (step 7). |
| The model ignores the prompt or invents a task | Make sure you are on the oMLX backend (`--local-status`). The optional Ollama backend (`CLAUDE_LOCAL_BACKEND=ollama`) misbehaved this way on Ollama 0.30.10 and needs a newer Ollama. |
| Slow first reply in a new session | Claude Code's ~16K-token prompt is being processed cold: on the MacBook Pro about 5–10 s with the fast model and 30–40 s with the quality model; on a 16 GB M2 about 30 s even in lean mode. Later turns reuse the SSD prefix cache. |
| `the quality model ... is not installed` (or laguna) | Run `./install-claude-local.sh --with-quality` (or `--with-laguna`). |
| `no quality model on this Mac` (or laguna) | That model doesn't fit this Mac's memory; `claude-local --local-status` lists the ones that do. |
| `... has no image input; drop --local-vision` | Laguna, and the 16 GB Mac's model, are text only. Use `--local-fast --local-vision` on a Mac with 36 GB or more. |
| With Laguna, an Edit fails with identical old and new strings, or a written file loses its final newline | oMLX 0.7.0rc1's Laguna tool parser strips leading and trailing whitespace from tool arguments. Indentation-only edits can't be made through Laguna; do them with a Qwen model or by hand. |
| Laguna thinks for a very long time | Poolside lists overthinking as a known limitation. Output is capped at 32K tokens per reply; interrupt and rephrase, or switch to a Qwen model for that task. |
| The model says it can't see an image | Vision is off: relaunch with `--local-vision`. With vision off, image reads are refused and pasted images are dropped. |
| The vision model misreads small text | Small images get few image tokens: a 480×200 image lost a digit that 640×400 kept. Use full-size screenshots rather than tiny crops. |
| `oMLX is running but doesn't list '<model>'` | The server started before that model or its settings were installed. Run `claude-local --local-stop` (or re-run the installer with `--restart-server`); the next launch rescans the models. |
| Warning that a model "was used Ns ago, probably by another session" | Another `claude-local` window is using a different model. This launch swaps it out, and that window's next request swaps it back, each costing a reload. Use the same model in both, or accept the reloads. |
| Everything is slow, or the Mac is swapping | Another large memory user is running: OrbStack or Docker VMs, Ollama or LM Studio with a model loaded. `claude-local` warns about these at launch. |
| Claude Code updated and `claude-local` broke | Normal `claude` is unaffected. Run `claude-local -p "Reply OK"` and read the error. Check the environment variables in the wrapper against the new release's docs. |

## Updating

- **oMLX:** repeat step 2 with a new `OMLX_TAG`. Stop the server first with `claude-local --local-stop`. The config in `~/.omlx` is kept. Re-run steps 8b–8g, or `./install-claude-local.sh --memory-test`: the release after 0.7.0rc1 changes what the memory guard tiers mean, so windows need re-measuring.
- **Models:** to try another model, download it into a new folder under `~/.omlx/models/` and add an entry to `model_settings.json` with its own alias (not starting with `claude-`). Run it with `CLAUDE_LOCAL_MODEL=<alias> CLAUDE_LOCAL_CTX=<window> claude-local`, and measure its window first (step 8g); memory use changes with every model.
  - To make it the fast, quality or laguna model for a class of Mac, change that row of `catalog` in `src/claude-local`, add its entry (and a `-vision` entry if it has vision) to `src/model_settings.json`, and run `python3 scripts/build.py`. The build fails if an entry is missing.
  - A new named choice beyond those three also needs the option parsing, the `CLAUDE_LOCAL_PROFILE` and defaults checks, and the status loop.
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

- **Why the fast model:** Qwen3.6-35B-A3B is a mixture-of-experts model with 3B active parameters, so it runs at about 80+ tokens/s on a 32-core M5 Max. Only 10 of its 40 layers keep a normal attention cache (about 20 KiB per token), so long contexts are cheap.
- **The quality model:** Qwen3.8-27B (August 2026) is a dense 27B model. Its vendor benchmarks are well ahead of Qwen3.6-35B-A3B (SWE-bench Pro 61.7 against 49.5), but nobody has reproduced them independently, and they were run at full precision with a 256K context. Here it's a 4-bit build at up to a 92K window, and it generates about 2–4× slower and processes prompts about 3–4× slower. On the one coding test run here, both models passed. The build is `oQ4e-mtp` from oMLX's author, one of the few 4-bit MLX builds that keep the model's multi-token-prediction head.
- **Vision:** both models accept images. oMLX's text engine silently drops images, and its vision engine costs 1.1–2.3 GB more memory. A symlinked second folder is the way to give the same weights two engine settings, because oMLX ties the engine choice to the model's folder.
- **Why the Unsloth build:** its dynamic 4-bit quantization measures about 3× closer to the full-precision model than uniform 4-bit (KL divergence 0.029 vs 0.088), for about 1 GB more. 5-bit and larger don't leave room for context on a 36 GB Mac.
- **Why oMLX:** it serves the Anthropic Messages API natively. It removes Claude Code's cache-breaking per-request markers, accepts mid-conversation system messages and adaptive thinking, and has a paged prefix cache on SSD. Version 0.7.0rc1 or later is needed for the bounded long-prompt attention path and the partial-block cache reuse for this model family.
- **Why not 32K context:** Claude Code auto-compacts at the window minus about 33K, which a 32K window is already below.
- **Why Laguna:** it was requested alongside Qwen. Poolside trained it for long agentic coding sessions.
  - **XS 2.1** is the only Laguna that fits a 36 GB Mac. By Poolside's own published numbers it trails Qwen3.6-35B-A3B on every coding benchmark, so it is an option there rather than the default.
  - **S 2.1** is roughly level with Qwen3.8-27B on published numbers, and is the default on the Studios, where it fits comfortably. Its `-fast` build keeps the same 4-bit experts with slightly lower-precision attention: it decodes 14–24% faster with no measurable accuracy loss.
  - **No Laguna build fits a 16 GB Mac.** The smallest (XS 2.1 at 2-bit, 11.8 GB) is about the whole GPU budget.
- **Why these builds on the Studios:** 6-bit Qwen is close to full precision (unsloth measured KL divergence 0.0037 at 6-bit against 0.023 at 4-bit on Qwen3.6-27B), and with the multi-token-prediction head it stays as fast as 4-bit. 8-bit adds little, costs 7 GB more and is slower without the head.
- **Why Qwen3.5-9B on 16 GB:** no Qwen3.6 or Qwen3.8 model fits, even at 2-bit, with room for a 64K window. The fp16 build matters because M1 and M2 GPUs emulate bf16, which makes bf16 builds about 40% slower at prefill there.
