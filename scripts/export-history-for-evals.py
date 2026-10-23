#!/usr/bin/env python3
"""Export VoxBox History takes (raw engine text + what was pasted) for the
cleanup eval. Output is gitignored: dictations are private.

    python3 -I scripts/export-history-for-evals.py            # release app
    python3 -I scripts/export-history-for-evals.py --dev      # VoxBox-Dev

Writes evals/cleanup/history.local.json, newest first.
"""
import json
import os
import pathlib
import plistlib
import subprocess
import sys

DOMAINS = {"release": "dev.edlittle.VoxBox", "dev": "dev.edlittle.VoxBox.dev"}


def load(domain):
    out = subprocess.run(
        ["/usr/bin/defaults", "export", domain, "-"], capture_output=True, check=False
    )
    if out.returncode != 0 or not out.stdout:
        return []
    prefs = plistlib.loads(out.stdout)
    blob = prefs.get("history_items")
    if not blob:
        return []
    return json.loads(blob)


def main():
    domain = DOMAINS["dev" if "--dev" in sys.argv else "release"]
    items = load(domain)
    takes = []
    for item in items:
        raw = (item.get("rawTranscript") or "").strip()
        if not raw:
            continue  # Pre-1.3 items have no raw text to re-run.
        takes.append(
            {
                "id": item.get("id"),
                "date": item.get("date"),
                "durationSeconds": round(item.get("duration") or 0, 1),
                "speechModel": item.get("modelUsed"),
                "raw": raw,
                "pasted": (item.get("transcript") or "").strip(),
            }
        )
    root = pathlib.Path(__file__).resolve().parent.parent
    dest = root / "evals" / "cleanup" / "history.local.json"
    dest.parent.mkdir(parents=True, exist_ok=True)
    # Private dictation: owner-only permissions, and never follow a symlink
    # someone left at the destination.
    if dest.is_symlink():
        sys.exit(f"Refusing to write through a symlink: {dest}")
    fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(json.dumps({"domain": domain, "takes": takes}, indent=2, ensure_ascii=False))
    os.chmod(dest, 0o600)
    print(f"{len(takes)} takes with raw text (of {len(items)} items) from {domain} -> {dest}")


if __name__ == "__main__":
    main()
