# local-models

`claude-local` runs Claude Code against a local open-weight model on an Apple Silicon Mac: Qwen3.6-35B-A3B, served by oMLX. The normal `claude` command, its login, settings and history are unaffected, and the install needs no admin rights.

Tested on a MacBook Pro with an M5 Max (32-core GPU) and 36 GB, running macOS 27.0 and Claude Code 2.1.283. It needs Apple Silicon, at least 36 GB of memory and macOS 15 or later.

## Install

```sh
gh repo clone Marlin-Research-Labs/local-models
cd local-models
./install-claude-local.sh                  # install, then run the checks
./install-claude-local.sh --memory-test    # also run the full-context memory test
```

The script is safe to re-run. [INSTALL.md](INSTALL.md) has the same steps done by hand, a sizing guide for other Macs, troubleshooting and updating.

## Use

```sh
claude-local                    # interactive session, same flags as claude
claude-local -p "question"      # print mode
claude-local --local-status     # server and model status, memory warnings
claude-local --local-start      # start the server and load the model ahead of time
claude-local --local-stop       # stop the server and free ~20 GB
claude-local --local-help
```

The first launch starts the server and loads the model (about 10–15 s). The model unloads after 30 minutes idle. For best performance, stop OrbStack first (`orbctl stop`).

## What is installed

| Piece | Location |
|---|---|
| Wrapper | `~/.local/bin/claude-local` |
| Claude Code profile for local sessions | `~/.claude-local/` (settings, history, sessions). `CLAUDE.md` is a symlink to `~/.claude/CLAUDE.md` |
| Inference server | oMLX 0.7.0rc1, `~/Applications/oMLX.app`, run headless by the wrapper on `127.0.0.1:8765` |
| Server config | `~/.omlx/settings.json`, `~/.omlx/model_settings.json` |
| Model | `~/.omlx/models/Qwen3.6-35B-A3B-UD-MLX-4bit` (Unsloth dynamic 4-bit, 21.7 GB) |
| Prompt cache and logs | `~/.omlx/cache` (capped at 50 GB), `~/.omlx/logs/claude-local-server.log` |

The install uses no admin rights and changes nothing in `~/.claude`, `~/.claude.json`, shell startup files or launchd.

## Configuration choices

- **Model:** Qwen3.6-35B-A3B, a mixture-of-experts model with 3B active parameters. It was the best balance of speed and quality that fits in 36 GB.
- **Quantization:** Unsloth UD-MLX-4bit instead of uniform 4-bit, because it measures roughly 3× closer to full precision.
- **Text-only loading:** the model is loaded without its vision tower, which frees about 1.2 GB.
- **Context:** Claude Code plans for a 128K window and auto-compacts at about 98K. Claude Code's own prompt and tools use about 16K of it.
- **Memory:** the largest prompt Claude Code sends at this window (~108K tokens) works: 55 s cold, 5 s with the prefix cached. It peaks at about 27 GB against the 28.1 GB GPU limit, which needs oMLX's `aggressive` memory guard.
- **Sampling:** Qwen's settings for precise coding: temperature 0.6, top_p 0.95, top_k 20. Thinking is on and preserved across turns.
- **Permission mode:** the default permission mode is normal prompting, not auto mode, because auto mode's safety checks would be judged by the local model.
- **Disabled tools:** WebSearch is disabled because it runs on Anthropic's servers. The claude.ai connectors and MCP servers are also off; pass `--mcp-config <file>` to add servers.
- **Speed:** measured on the tested Mac at about 70–90 tokens/s generation and about 1,500–1,900 tokens/s prefill for long prompts. Repeat turns reuse the prompt cache (about 98% hits).

## Privacy note

Inference is local, but any organization-managed Claude Code settings still apply. On Marlin Macs, the MintMCP hooks and OTEL telemetry send prompts and tool events off the machine, exactly as with normal `claude`.

## Overrides

Set these per invocation, for example `CLAUDE_LOCAL_CTX=65536 claude-local`:

- `CLAUDE_LOCAL_CTX`: context window (default 131072)
- `CLAUDE_LOCAL_MAX_OUT`: max output tokens (default 32000)
- `CLAUDE_LOCAL_MODEL`, `CLAUDE_LOCAL_PORT`
- `CLAUDE_LOCAL_BACKEND=ollama`: fallback to Ollama with `qwen3.6:35b-a3b-coding-nvfp4`. It is wired up, but the installed Ollama 0.30.10 misbehaved in testing, so update Ollama before relying on it.

## Uninstall

```sh
claude-local --local-stop
rm ~/.local/bin/claude-local ~/.local/bin/claude-local.bak-* 2>/dev/null
rm -rf ~/.claude-local ~/.omlx ~/Applications/oMLX.app ~/Downloads/omlx ~/claude-local-baseline
```

If oMLX was set up on the Mac before `claude-local`, keep `~/.omlx` and restore the originals from `~/.omlx/*.pre-claude-local` instead.

## Repository layout

| Path | What it is |
|---|---|
| `install-claude-local.sh` | The installer. **Generated.** |
| `INSTALL.md` | The manual install guide. **Generated.** |
| `src/claude-local` | The wrapper that the installer puts in `~/.local/bin` |
| `src/model_settings.json` | oMLX per-model settings for Qwen3.6-35B-A3B |
| `src/INSTALL.md.in`, `src/install-claude-local.sh.in` | Templates for the generated files |
| `scripts/build.py` | Regenerates the generated files from `src/` |

The generated files embed the wrapper and model settings verbatim, so edit `src/` and run `python3 scripts/build.py` rather than editing them directly. `python3 scripts/build.py --check` fails if they are out of date.
