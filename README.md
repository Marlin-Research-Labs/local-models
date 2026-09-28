# local-models

`claude-local` runs Claude Code against a local open-weight model on an Apple Silicon Mac, served by oMLX: Qwen3.6-35B-A3B by default, or the slower, stronger Qwen3.8-27B, either with or without image input. The normal `claude` command, its login, settings and history are unaffected, and the install needs no admin rights.

Tested on a MacBook Pro with an M5 Max (32-core GPU) and 36 GB, running macOS 27.0 and Claude Code 2.1.283. It needs Apple Silicon, at least 36 GB of memory and macOS 15 or later.

## Install

```sh
gh repo clone Marlin-Research-Labs/local-models
cd local-models
./install-claude-local.sh
```

| Command | What it does |
|---|---|
| `./install-claude-local.sh` | The fast model, then the checks |
| `./install-claude-local.sh --with-quality` | Also the quality model (17 GB more); can be added later |
| `./install-claude-local.sh --memory-test` | Also test every installed model at full context |

The script is safe to re-run. [INSTALL.md](INSTALL.md) has the same steps done by hand, a sizing guide for other Macs, troubleshooting and updating.

## Use

| Command | What it does |
|---|---|
| `claude-local` | Fast model, text only (the default); same flags as claude |
| `claude-local --local-vision` | Fast model with image input |
| `claude-local --local-quality` | Qwen3.8-27B: slower, stronger |
| `claude-local --local-quality --local-vision` | Qwen3.8-27B with image input |
| `claude-local -p "question"` | Print mode; wrapper options always go first |
| `claude-local --local-quality --local-set-default` | Save a different default |
| `claude-local --local-status` | Selection, server, installed models, memory warnings |
| `claude-local --local-start` | Load the selected model ahead of time |
| `claude-local --local-stop` | Stop the server and free the model's memory |
| `claude-local --local-help` | Show the wrapper's options |

| Choice | Context window | Generation | Prompt processing |
|---|---|---|---|
| fast | 128K | ~70–90 tok/s | ~1,500–1,900 tok/s |
| fast + vision | 104K | ~70–90 tok/s | ~1,900 tok/s |
| quality | 92K | ~20–45 tok/s | ~450–550 tok/s |
| quality + vision | 80K | ~20–45 tok/s | ~530 tok/s |

`CLAUDE_LOCAL_PROFILE=fast|quality` and `CLAUDE_LOCAL_VISION=on|off` also choose, per command or per shell. Precedence is option, then environment, then the saved default in `~/.config/claude-local/defaults` (or `$XDG_CONFIG_HOME/claude-local/defaults` if you set that), then fast with vision off.

The first launch starts the server and loads the model (about 10–15 s). Only one model fits in memory, so switching loads the other one, and `claude-local` warns if another session used a different model in the last 10 minutes. Models unload after 30 minutes idle. For best performance, stop OrbStack first (`orbctl stop`).

## What is installed

| Piece | Location |
|---|---|
| Wrapper | `~/.local/bin/claude-local` |
| Claude Code profile for local sessions | `~/.claude-local/` (settings, history, sessions). `CLAUDE.md` is a symlink to `~/.claude/CLAUDE.md` |
| Inference server | oMLX 0.7.0rc1, `~/Applications/oMLX.app`, run headless by the wrapper on `127.0.0.1:8765` |
| Server config | `~/.omlx/settings.json`, `~/.omlx/model_settings.json` |
| Models | `~/.omlx/models/Qwen3.6-35B-A3B-UD-MLX-4bit` (Unsloth dynamic 4-bit, 21.7 GB) and, with `--with-quality`, `~/.omlx/models/Qwen3.8-27B-oQ4e-mtp` (17.0 GB). Each has a `-vision` symlink served by oMLX's vision engine. |
| Saved defaults | `~/.config/claude-local/defaults` (or `$XDG_CONFIG_HOME/claude-local/defaults` if you set that), only after `--local-set-default` |
| Prompt cache and logs | `~/.omlx/cache` (capped at 50 GB), `~/.omlx/logs/claude-local-server.log` |

The install uses no admin rights and changes nothing in `~/.claude`, `~/.claude.json`, shell startup files or launchd.

## Configuration choices

- **Fast model:** Qwen3.6-35B-A3B, a mixture-of-experts model with 3B active parameters. It was the best balance of speed and quality that fits in 36 GB.
- **Quality model:** Qwen3.8-27B (dense). Its vendor benchmarks are well ahead (SWE-bench Pro 61.7 against 49.5), not yet independently reproduced. It generates 2–4× slower, and fits less context because its attention cache is 3.2× larger per token. It uses Qwen's thinking-mode sampling (temperature 1.0), `reasoning_effort` medium (its default `xhigh` can think for minutes) and its multi-token-prediction head. It also needs one undocumented Claude Code setting, because its chat template rejects mid-conversation system messages.
- **Quantization:** Unsloth UD-MLX-4bit instead of uniform 4-bit, because it measures roughly 3× closer to full precision.
- **Vision:** off by default, because the vision engine costs 1.1–2.3 GB of memory and so a smaller context window. With vision off, oMLX drops images silently. `claude-local` therefore refuses Claude Code's Read tool on image files, with a message telling the model to suggest `--local-vision`; Glob and Grep still list image files.
- **Context:** each model and vision setting has its own measured window (table above). Claude Code auto-compacts about 33K below the window and never sends more than about 23K below it. Its own prompt and tools use about 16K.
- **Memory:** each window was tested cold with the largest prompt Claude Code sends at it, and every one peaked at about 26 GB against the 28.1 GB GPU limit. That needs oMLX's `aggressive` memory guard.
- **Sampling (fast model):** Qwen's settings for precise coding: temperature 0.6, top_p 0.95, top_k 20. Thinking is on and preserved across turns for both models.
- **Permission mode:** the default permission mode is normal prompting, not auto mode, because auto mode's safety checks would be judged by the local model.
- **Disabled tools:** WebSearch is disabled because it runs on Anthropic's servers. The claude.ai connectors and MCP servers are also off; pass `--mcp-config <file>` to add servers.
- **Speed:** see the table above. Repeat turns reuse the prompt cache (about 98% hits for both models).

## Compared with `ollama launch claude`

Ollama can also start Claude Code against a local model, with `ollama launch claude --model <model>`. Both approaches set environment variables only for the Claude Code process, so neither changes how the normal `claude` command runs. The difference is how much is tuned for long Claude Code agent sessions. The Ollama details below come from its launcher source at v0.34.4.

| | `ollama launch claude` | `claude-local` |
|---|---|---|
| Setup | One app: `ollama pull`, then `ollama launch claude` | oMLX run headless, a wrapper script, a separate profile and two config files, all set up by `install-claude-local.sh` |
| Claude Code profile | Your normal `~/.claude`: same settings, history and hooks. `/model` or `/config` in a local session writes to your normal settings. | A separate `~/.claude-local`, with its own settings, history and Keychain entry |
| Context window | Not declared, so Claude Code assumes 200K. Ollama's context is set on the server (32K by default on a 36 GB Mac), so long prompts can be cut off before Claude Code thinks it needs to compact. | Declared (128K), so Claude Code compacts before the server's limit |
| MCP servers | Servers configured in your normal profile or the project still load, and their tool definitions are sent in full with every request | Off by default (`--strict-mcp-config`). WebSearch and LSP are disabled. |
| Prompt cache | In memory only, lost when the model unloads (after 5 idle minutes by default). Earlier reasoning is dropped each turn, forcing recomputation. | On SSD, surviving unloads and restarts. Reasoning is kept; about 98% cache hits were measured. |
| Model build | Ollama's nvfp4 build; no published quality measurement | Unsloth mixed 4-bit, measured about 3× closer to full precision than plain 4-bit |
| Memory | Peaked at 26.9 GB with a ~20K-token prompt (0.30.10, 128K context configured) | A memory guard rejects prompts that won't fit. About 20 GB at small contexts, about 26 GB at the largest prompt Claude Code sends. |
| Single-model tuning | Model mapping and two cache-stability switches | Also caps subagents at one, raises timeouts, defaults to normal permission prompts and warns about memory use |
| Other uses | Codex, OpenCode and other tools; Ollama's cloud models; any model available through `ollama pull` | Claude Code only. oMLX has its own launcher for other tools. |

In testing with Ollama 0.30.10, the same Qwen3.6 model ignored a one-line prompt and invented an unrelated task over 22 turns. Later Ollama releases fix an nvfp4 output-quality bug (0.32.5) and cache bugs (0.33.0) that may explain it; that hasn't been re-tested. `claude-local` passed every test on the same Mac.

Ollama's launcher is the quicker way to try models. `claude-local` is tuned for long Claude Code sessions on a 36 GB Mac: no silent context truncation, warm caches across turns and restarts, a separate profile and a higher-quality quantization. To combine the two, run `CLAUDE_LOCAL_BACKEND=ollama claude-local`, which uses Ollama's server with this wrapper's settings. Update Ollama first.

## Compared with other open-source coding agents

Several open-source agents work like Claude Code but send a much smaller prompt, which in principle suits a local model better. This is desk research from September 27, 2026. None of these agents was installed or run on the tested Mac.

| Agent | License, version | First-request prompt | Connects to oMLX | Main drawback |
|---|---|---|---|---|
| Claude Code (what `claude-local` runs) | Proprietary, 2.1.283 | ~16K tokens (measured here: tools 12.7K, skills 1.8K, system prompt 1.1K, CLAUDE.md 0.4K) | Anthropic API, as `claude-local` does | Largest prompt, and it reserves ~33K for compaction |
| [Pi](https://github.com/earendil-works/pi) | MIT, v0.87.1 | ~1.5K (4 tools; the prompt doesn't change between sessions, so it caches well) | Built in: `omlx launch pi` | No permission prompts by default; no MCP, plan mode or subagents without extensions |
| [Qwen Code](https://github.com/QwenLM/qwen-code) | Apache-2.0, 0.24.6 | Base prompt 3.5–3.9K; full size with tools not measured, probably over 7K | OpenAI API, configured by hand | Its advantage is tuning for Qwen by Qwen's own team; the prompt-size benefit is unproven |
| [little-coder](https://github.com/itayinbarr/little-coder) | Apache-2.0, 1.20.0 | ~7K (its own claim, not measured) | Through Pi, configured by hand | Built for Qwen3.6-35B-A3B but little independent testing; no permission prompts |
| [OpenCode](https://github.com/anomalyco/opencode) | MIT, v1.18.32 | ~7.5K (11 tools) | Built in: `omlx launch opencode` | Puts today's date in its prompt, so the prompt cache resets daily; mixed local results |
| [Codex CLI](https://github.com/openai/codex) | Apache-2.0, rust-v0.157.1 | ~8.7K (9 tools); ~25K once MCP servers are configured | Built in: `omlx launch codex` (OpenAI Responses API) | Depends on oMLX's Responses API; MCP servers inflate the prompt |

Prompt sizes other than Claude Code's were counted offline, with the Qwen3.6 tokenizer, on prompts taken from each project's source; they are not live captures. Only Pi's count was reproduced independently.

What third-party results say, with the same local model in different agents:

- **Accuracy barely changes with the agent.** In one small benchmark ([harness-bench](https://neuralnoise.com/2026/harness-bench-wip/), April 28, 2026: 16 tasks, 10 local models at 4-bit on an M3 Max, thinking off, and called "very preliminary" by its author):
  - Across all ten models, Pi passed 77% of tasks at 163 s each, Qwen Code 75% at 191 s, Claude Code 66% at 306 s, and OpenCode 64% at 271 s. OpenCode's figure drops to about 55% without the runs where it read the hidden grading files.
  - For Qwen3.6-35B-A3B specifically: Qwen Code 15 of 16, Claude Code 14 of 16 (15 at 8-bit), and Pi 11 of 16.
- **Other results point the same way:**
  - A study of three agents ([arXiv 2607.22585](https://arxiv.org/abs/2607.22585)) found pass rates within 0–8 points of each other.
  - On Terminal-Bench 2.1, Qwen3.6-35B-A3B scored 52.5 in a minimal agent and 49.2 in Claude Code (from the [Ornith-1.5 model card](https://huggingface.co/ornith-ai/Ornith-1.5-35B-A3B)).
- **Speed and tokens change more.**
  - The same study found up to a 40× difference in tokens per solved task.
  - One tester ([Vaughan](https://codex.danielvaughan.com/2026/04/19/does-pi-outperform-codex-cli-for-local-models/), NVIDIA GB10 with Ollama) found Pi 2.1× faster than Codex on a dense 31B model, but about even on mixture-of-experts models like the fast model here.
  - In that test, Pi also failed on Qwen3.6-35B-A3B by writing its files to `/tmp`. A later Pi release addresses that, but hasn't been re-tested.
  - A stripped-down Codex prompt was 24% faster on this model.

Why the gain is smaller with this setup:
- **Speed:** Claude Code's 16K prompt stays the same from turn to turn, and oMLX caches it on disk, so its cost is paid mostly once per session (about 5–10 s with the fast model).
- **Context room:** before any work, Claude Code uses about 49K of the 128K window, counting its compaction reserve. Pi uses about 18K. A leaner agent's real advantage here is that room, not accuracy, and a trimmed Claude Code (below) gets much of it.

What moving off Claude Code would lose:
- **Features:** permission prompts and modes, plan mode, subagents, hooks, skills, MCP servers, rewind and IDE integrations.
- **Governance:** Marlin's managed settings (the MintMCP hooks and telemetry) apply only to Claude Code. Any other agent would run outside those controls, and whether that's acceptable is Marlin's decision.

A middle path keeps Claude Code and Marlin's controls: trim its tools for one session with `claude-local --tools=Read,Edit,Write,Bash,Grep,Glob --disable-slash-commands`. On the tested Mac this cut the first-request prompt from about 16K tokens to about 4.5K, smaller than OpenCode's or Codex's and within about 3K of Pi's. It does give up plan mode, subagents, skills and the other tools.

To compare properly, run the same 5–10 real tasks through Pi, Qwen Code and a trimmed Claude Code, recording passes, time and turns.

## Privacy note

Inference is local, but any organization-managed Claude Code settings still apply. On Marlin Macs, the MintMCP hooks and OTEL telemetry send prompts and tool events off the machine, exactly as with normal `claude`.

## Overrides

For experiments, set these per invocation, for example `CLAUDE_LOCAL_CTX=65536 claude-local`:

- `CLAUDE_LOCAL_CTX`: context window (default: the chosen model's measured window)
- `CLAUDE_LOCAL_MAX_OUT`: max output tokens (default 32000 for fast, 20000 for quality)
- `CLAUDE_LOCAL_MODEL`: a served model name, overriding the chosen one
- `CLAUDE_LOCAL_PORT`: server port (default 8765)
- `CLAUDE_LOCAL_BACKEND=ollama`: fallback to Ollama with `qwen3.6:35b-a3b-coding-nvfp4` (fast model, no vision). It is wired up, but the installed Ollama 0.30.10 misbehaved in testing, so update Ollama before relying on it.

## Uninstall

```sh
claude-local --local-stop
rm -f ~/.local/bin/claude-local
find ~/.local/bin -name 'claude-local.bak-*' -delete
rm -rf ~/.claude-local ~/.omlx ~/Applications/oMLX.app ~/Downloads/omlx ~/claude-local-baseline
rm -rf "${XDG_CONFIG_HOME:-$HOME/.config}/claude-local"
```

If oMLX was set up on the Mac before `claude-local`, keep `~/.omlx` and restore the originals from `~/.omlx/*.pre-claude-local` instead.

## Repository layout

| Path | What it is |
|---|---|
| `install-claude-local.sh` | The installer. **Generated.** |
| `INSTALL.md` | The manual install guide. **Generated.** |
| `src/claude-local` | The wrapper that the installer puts in `~/.local/bin` |
| `src/model_settings.json` | oMLX per-model settings for both models and their vision variants |
| `src/INSTALL.md.in`, `src/install-claude-local.sh.in` | Templates for the generated files |
| `scripts/build.py` | Regenerates the generated files from `src/` |

The generated files embed the wrapper and model settings verbatim, so edit `src/` and run `python3 scripts/build.py` rather than editing them directly. `python3 scripts/build.py --check` fails if they are out of date.
