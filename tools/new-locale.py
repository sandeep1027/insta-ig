#!/usr/bin/env python3
"""Seed a new community catalog from English, ready to translate in place."""

from __future__ import annotations

import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENGLISH = ROOT / "resources" / "Sparkle.bundle" / "en.lproj"
TRANSLATIONS = ROOT / "translations"


def main(code: str) -> int:
    destination = TRANSLATIONS / f"{code}.lproj"
    if destination.exists():
        print(f"{destination.relative_to(ROOT)} already exists. Edit it instead.", file=sys.stderr)
        return 1

    destination.mkdir(parents=True)
    # Values start as English rather than empty, so a half-finished catalog is
    # still usable and the linter's leftover-English warnings double as the
    # to-do list.
    shutil.copyfile(ENGLISH / "Localizable.strings", destination / "Localizable.strings")
    shutil.copyfile(ENGLISH / "Localizable.stringsdict", destination / "Localizable.stringsdict")

    print(f"Seeded {destination.relative_to(ROOT)} from English.")
    print("Translate the right-hand side of each line, leaving keys untouched, then run:")
    print(f"  tools/lint-i18n.py --locale {code}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: new-locale.py <language-code>   e.g. new-locale.py nl", file=sys.stderr)
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1]))
