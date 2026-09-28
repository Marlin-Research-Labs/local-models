#!/usr/bin/env python3
"""Regenerate INSTALL.md and install-claude-local.sh from src/.

Both files embed src/claude-local and src/model_settings.json verbatim, so edit
src/ and run this script rather than editing the generated files by hand.

    python3 scripts/build.py           # rewrite whatever is out of date
    python3 scripts/build.py --check   # exit 1 if anything is out of date
"""

import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
HEREDOC_MARKERS = ("CLAUDE_LOCAL_SCRIPT", "CLAUDE_REMOTE_SCRIPT", "MODEL_ENTRIES")


def check_catalog(entries: dict) -> None:
    """Every model the wrapper can pick, on every class of Mac, needs oMLX settings."""
    missing = []
    for machine in ("16", "36", "96", "128"):
        env = dict(os.environ, CLAUDE_LOCAL_MACHINE=machine)
        out = subprocess.run([str(SRC / "claude-local"), "--local-catalog"], env=env,
                             capture_output=True, text=True, check=True).stdout
        status = subprocess.run([str(SRC / "claude-local"), "--local-status"], env=env,
                                capture_output=True, text=True)
        if status.returncode != 0 or "models on this Mac:" not in status.stdout:
            sys.exit(f"claude-local --local-status failed for a {machine} GB Mac:\n{status.stderr}")
        # What claude-remote asks a host for, for every model that fits it.
        for line in out.splitlines():
            profile, base = line.split("\t")[0], line.split("\t")[3]
            if base == "-":
                continue
            r = subprocess.run([str(SRC / "claude-local"), f"--local-{profile}", "--local-resolve"], env=env,
                               capture_output=True, text=True)
            lines = r.stdout.splitlines()
            keys = {l.split("=", 1)[0] for l in lines[1:]}
            want = {"class", "profile", "vision", "model", "ctx", "max_out", "caps", "has_vision",
                    "fast_vision", "lean", "server_port"}
            if r.returncode != 0 or not lines or lines[0] != "claude-local-resolve 1" or keys != want:
                sys.exit(f"claude-local --local-{profile} --local-resolve is wrong for a {machine} GB Mac:\n"
                         f"{r.stdout}{r.stderr}")
        for line in out.splitlines():
            profile, _, _, base, _, _, _, vision_ctx = line.split("\t")[:8]
            if base == "-":
                continue
            for folder in [base] + ([base + "-vision"] if vision_ctx != "-" else []):
                if folder not in entries:
                    missing.append(f"{folder} ({machine} GB {profile})")
    if missing:
        sys.exit("src/model_settings.json has no entry for: " + ", ".join(sorted(set(missing))))


def render() -> dict[str, str]:
    wrapper = (SRC / "claude-local").read_text().rstrip("\n")
    remote = (SRC / "claude-remote").read_text().rstrip("\n")
    model_settings = (SRC / "model_settings.json").read_text().rstrip("\n")
    entries = json.loads(model_settings)["models"]
    check_catalog(entries)
    for marker in HEREDOC_MARKERS:
        if marker in wrapper or marker in remote or marker in model_settings:
            sys.exit(f"src/ must not contain the heredoc marker {marker}")

    guide = (SRC / "INSTALL.md.in").read_text()
    guide = guide.replace("@@WRAPPER@@", wrapper).replace("@@MODEL_SETTINGS@@", model_settings)
    installer = (SRC / "install-claude-local.sh.in").read_text()
    installer = installer.replace("@@WRAPPER@@", wrapper).replace("@@REMOTE_WRAPPER@@", remote)
    installer = installer.replace("@@MODEL_ENTRIES@@", json.dumps(entries, indent=2))
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
            # Replace the file rather than rewrite it: bash reads a running
            # script as it goes, and a rename leaves its open copy intact.
            tmp = path.with_name(f".{name}.tmp")
            tmp.write_text(text)
            tmp.chmod(0o755 if name.endswith(".sh") else 0o644)
            os.replace(tmp, path)
    if check and stale:
        sys.exit(f"out of date: {', '.join(stale)} (run python3 scripts/build.py)")
    print("wrote " + ", ".join(stale) if stale else "up to date")


if __name__ == "__main__":
    main()
