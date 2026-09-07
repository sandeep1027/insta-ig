#!/usr/bin/env python3
"""Subset of /usr/libexec/PlistBuddy used by Sparkle's Linux-hosted IPA packaging."""

from __future__ import annotations

import argparse
import plistlib
import sys
from typing import Any


def parse_entry(entry: str) -> list[Any]:
    if entry.startswith(":"):
        entry = entry[1:]
    if not entry:
        return []
    parts: list[Any] = []
    for part in entry.split(":"):
        parts.append(int(part) if part.isdigit() else part)
    return parts


def load_plist(path: str) -> Any:
    with open(path, "rb") as handle:
        return plistlib.load(handle)


def save_plist(path: str, data: Any) -> None:
    with open(path, "wb") as handle:
        plistlib.dump(data, handle, fmt=plistlib.FMT_BINARY)


def resolve_parent(root: Any, parts: list[Any]) -> tuple[Any, Any]:
    current = root
    for part in parts[:-1]:
        current = current[part]
    return current, parts[-1]


def coerce_value(type_name: str, raw: str | None) -> Any:
    if type_name == "dict":
        return {}
    if type_name == "array":
        return []
    if type_name == "string":
        return "" if raw is None else raw
    if type_name == "bool":
        if raw is None:
            raise ValueError("bool requires a value")
        return raw.lower() in ("true", "yes", "1")
    if type_name == "integer":
        return int(raw or "0")
    if type_name == "real":
        return float(raw or "0")
    raise ValueError(f"unsupported type {type_name}")


def cmd_add(root: Any, command: str) -> None:
    tokens = command.split()
    if len(tokens) < 2:
        raise ValueError("Add requires an entry and a type")
    entry, type_name, *rest = tokens
    value = coerce_value(type_name, " ".join(rest) if rest else None)
    parts = parse_entry(entry)
    if not parts:
        raise ValueError("Add requires a path")
    parent, key = resolve_parent(root, parts)
    if isinstance(key, int):
        if not isinstance(parent, list) or key < 0 or key > len(parent):
            raise KeyError(entry)
        parent.insert(key, value)
        return
    if not isinstance(parent, dict) or key in parent:
        raise KeyError(entry)
    parent[key] = value


def cmd_delete(root: Any, command: str) -> None:
    entry = command.strip()
    parts = parse_entry(entry)
    if not parts:
        raise ValueError("Delete requires a path")
    parent, key = resolve_parent(root, parts)
    if isinstance(parent, list):
        del parent[key]
    else:
        del parent[key]


def cmd_set(root: Any, command: str) -> None:
    tokens = command.split(None, 1)
    if len(tokens) != 2:
        raise ValueError("Set requires an entry and a value")
    entry, raw = tokens
    parts = parse_entry(entry)
    if not parts:
        raise ValueError("Set requires a path")
    parent, key = resolve_parent(root, parts)
    current = parent[key]
    if isinstance(current, bool):
        parent[key] = raw.lower() in ("true", "yes", "1")
    elif isinstance(current, int) and not isinstance(current, bool):
        parent[key] = int(raw)
    elif isinstance(current, float):
        parent[key] = float(raw)
    else:
        parent[key] = raw


def cmd_print(root: Any, command: str) -> None:
    entry = command.strip()
    if not entry:
        print(root)
        return
    parts = parse_entry(entry)
    current = root
    for part in parts:
        current = current[part]
    print(current)


def run_command(root: Any, command: str) -> None:
    command = command.strip()
    if not command:
        return
    verb, _, rest = command.partition(" ")
    verb = verb.lower()
    if verb == "add":
        cmd_add(root, rest)
    elif verb == "delete":
        cmd_delete(root, rest)
    elif verb == "set":
        cmd_set(root, rest)
    elif verb == "print":
        cmd_print(root, rest)
    else:
        raise ValueError(f"unsupported command {verb}")


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("-c", action="append", dest="commands", default=[])
    parser.add_argument("plist")
    args = parser.parse_args()
    try:
        root = load_plist(args.plist)
        for command in args.commands:
            run_command(root, command)
        if any(cmd.strip().split(" ", 1)[0].lower() != "print" for cmd in args.commands):
            save_plist(args.plist, root)
    except Exception:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
