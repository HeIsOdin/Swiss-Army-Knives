#!/usr/bin/env python3

import os
import re
import sys
from pathlib import Path

FLAG_PATTERNS = [
    re.compile(rb"flag\{[^}\r\n]{1,300}\}", re.IGNORECASE),
    re.compile(rb"ctf\{[^}\r\n]{1,300}\}", re.IGNORECASE),
    re.compile(rb"picoCTF\{[^}\r\n]{1,300}\}", re.IGNORECASE),
    re.compile(rb"HTB\{[^}\r\n]{1,300}\}", re.IGNORECASE),
    re.compile(rb"THM\{[^}\r\n]{1,300}\}", re.IGNORECASE),
]

INTERESTING_NAME = re.compile(
    r"flag|secret|proof|token|user\.txt|root\.txt|ctf",
    re.IGNORECASE,
)

MAX_FILE_SIZE = 50 * 1024 * 1024  # 50 MB

SHELL_FILES = [
    ".bashrc",
    ".bash_profile",
    ".profile",
    ".bash_history",
    ".zshrc",
    ".zprofile",
    ".zsh_history",
    ".config/fish/config.fish",
    ".local/share/fish/fish_history",
]


def find_flags(data: bytes):
    """Return all flag-like strings found in data."""
    found = []

    for pattern in FLAG_PATTERNS:
        for match in pattern.finditer(data):
            flag = match.group().decode("utf-8", errors="replace")
            if flag not in found:
                found.append(flag)

    return found


def check_environment():
    """Search the current process/shell environment."""
    print("\n[*] Checking environment variables...")

    for name, value in os.environ.items():
        data = f"{name}={value}".encode()

        for flag in find_flags(data):
            print(f"[FLAG][ENV] {name}")
            print(f"            {flag}")

        if re.search(r"flag|ctf|secret", name, re.IGNORECASE):
            print(f"[Interesting ENV] {name}={value}")


def search_file(path: Path):
    try:
        if not path.is_file():
            return

        size = path.stat().st_size

        if size > MAX_FILE_SIZE:
            return

        data = path.read_bytes()

        for flag in find_flags(data):
            print(f"[FLAG] {path}")
            print(f"       {flag}")

    except (PermissionError, OSError):
        pass


def check_shell_files(home: Path):
    """Inspect common shell config/history files."""
    print("\n[*] Checking common shell files...")

    for relative_path in SHELL_FILES:
        path = home / relative_path

        if path.exists():
            print(f"[*] Shell file: {path}")
            search_file(path)


def search_directory(root: Path):
    print(f"\n[*] Recursively searching: {root}")

    for current_dir, dirs, files in os.walk(root):
        current = Path(current_dir)

        for filename in files:
            path = current / filename

            if INTERESTING_NAME.search(filename):
                print(f"[Interesting filename] {path}")

            search_file(path)


def main():
    home = Path.home()

    # Default to HOME when no directory is supplied.
    if len(sys.argv) >= 2:
        target = Path(sys.argv[1]).expanduser().resolve()
    else:
        target = home

    if not target.is_dir():
        print(f"[-] Not a directory: {target}")
        sys.exit(1)

    print("=== CTF Flag Finder ===")
    print(f"[*] Home directory: {home}")
    print(f"[*] Search target:   {target}")

    # Current shell/process environment
    check_environment()

    # Shell configuration/history
    check_shell_files(home)

    # Files under target directory
    search_directory(target)


if __name__ == "__main__":
    main()