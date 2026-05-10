#!/usr/bin/env python3
"""Extract legacy service outputs from a device-pulled UserDefaults plist
for the G1 verification gate (#85). One-shot, single-user.

Reads the device's app-preferences plist directly (binary or XML) and
decodes the three relevant keys' Data blobs (each containing JSONEncoder
output of the legacy service's persisted array). Writes three JSON files
in <outputDir>; absent keys produce an empty array and a logged warning
so the gate report flags them explicitly rather than treating absence
as zero verdicts.

Why Python and not Deno: `plutil -convert json` aborts the entire
conversion if any value in the plist is not JSON-representable (e.g.
NSDate values in unrelated keys). Python's plistlib parses to native
types (Data → bytes, Date → datetime) so per-key extraction is robust.

Usage:
  python3 scripts/phase2-verification-gate/extract-legacy-outputs.py \\
    "/path/to/RTG.ProjectApex.plist" \\
    scripts/phase2-verification-gate/fixtures/
"""
import json
import plistlib
import sys
from pathlib import Path

KEYS = {
    "apex.stagnation_signals": "legacy-stagnation-signals.json",
    "apex.volume_deficits": "legacy-volume-deficits.json",
    "apex.pattern_phase_states": "legacy-pattern-phase-states.json",
}


def main() -> int:
    if len(sys.argv) != 3:
        print(
            "usage: extract-legacy-outputs.py <plist-path> <output-dir>",
            file=sys.stderr,
        )
        return 2

    plist_path, output_dir = sys.argv[1], sys.argv[2]

    with open(plist_path, "rb") as f:
        prefs = plistlib.load(f)

    out_dir = Path(output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    for key, filename in KEYS.items():
        out_path = out_dir / filename
        value = prefs.get(key)

        if value is None:
            print(
                f"[absent] key {key!r} not found — writing empty array",
                file=sys.stderr,
            )
            out_path.write_text("[]\n")
            continue

        if not isinstance(value, bytes):
            print(
                f"[malformed] key {key!r} expected Data blob (bytes); "
                f"got {type(value).__name__}; skipping",
                file=sys.stderr,
            )
            continue

        parsed = json.loads(value.decode("utf-8"))
        if not isinstance(parsed, list):
            print(
                f"[malformed] key {key!r} decoded value is not an array; "
                f"got {type(parsed).__name__}; skipping",
                file=sys.stderr,
            )
            continue

        out_path.write_text(json.dumps(parsed, indent=2) + "\n")
        print(f"[ok] {key} → {out_path} ({len(parsed)} entries)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
