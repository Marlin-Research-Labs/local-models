#!/usr/bin/env python3
"""Regenerate INSTALL.md and install-claude-local.sh from src/.

Both files embed src/claude-local and src/model_settings.json verbatim, so edit
src/ and run this script rather than editing the generated files by hand.

    python3 scripts/build.py           # rewrite whatever is out of date
    python3 scripts/build.py --check   # exit 1 if anything is out of date
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
MODEL_DIR_NAME = "Qwen3.6-35B-A3B-UD-MLX-4bit"
HEREDOC_MARKERS = ("CLAUDE_LOCAL_SCRIPT", "MODEL_ENTRY")


def render() -> dict[str, str]:
    wrapper = (SRC / "claude-local").read_text().rstrip("\n")
    model_settings = (SRC / "model_settings.json").read_text().rstrip("\n")
    entry = json.loads(model_settings)["models"][MODEL_DIR_NAME]
    for marker in HEREDOC_MARKERS:
        if marker in wrapper:
            sys.exit(f"src/claude-local must not contain the heredoc marker {marker}")

    guide = (SRC / "INSTALL.md.in").read_text()
    guide = guide.replace("@@WRAPPER@@", wrapper).replace("@@MODEL_SETTINGS@@", model_settings)
    installer = (SRC / "install-claude-local.sh.in").read_text()
    installer = installer.replace("@@WRAPPER@@", wrapper)
    installer = installer.replace("@@MODEL_ENTRY@@", json.dumps(entry, indent=2))
    return {"INSTALL.md": guide, "install-claude-local.sh": installer}


def main() -> None:
    check = "--check" in sys.argv[1:]
    stale = []
    for name, text in render().items():
        if "@@" in text:
            sys.exit(f"{name}: a placeholder was not replaced")
        path = ROOT / name
        if path.exists() and path.read_text() == text:
            continue
        stale.append(name)
        if not check:
            path.write_text(text)
            if name.endswith(".sh"):
                path.chmod(0o755)
    if check and stale:
        sys.exit(f"out of date: {', '.join(stale)} (run python3 scripts/build.py)")
    print("wrote " + ", ".join(stale) if stale else "up to date")


if __name__ == "__main__":
    main()
