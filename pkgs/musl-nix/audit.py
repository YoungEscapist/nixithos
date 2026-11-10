#!/usr/bin/env python3
"""Conservative preflight, not proof of a GNU-free Nix runtime closure."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys

p = argparse.ArgumentParser()
p.add_argument("closure", help="realized Nix output store path")
p.add_argument("--readelf", required=True, help="build-host readelf")
p.add_argument("--reviewed-static", action="append", default=[], metavar="FILE",
               help="static executable whose provenance was audited separately")
a = p.parse_args()
paths = subprocess.run(["nix-store", "-qR", a.closure], check=True, text=True, capture_output=True).stdout.splitlines()
forbidden = re.compile(r"-(?:glibc|gcc|xgcc|libgcc|bash|coreutils|gnugrep|gnused|gawk|findutils|gnutar|gzip|gnutls|libgcrypt|libidn2?|libunistring|libiconv|gettext|guile|gnupg)(?:[-.]|$)")
problems = []
static = []
files_checked = 0
for store in paths:
    print("closure:", store)
    if forbidden.search(Path(store).name):
        problems.append(f"forbidden package: {store}")
    root = Path(store)
    if root.is_file() and not root.is_symlink():
        files = [root]
    elif root.is_dir():
        files = (Path(d) / name for d, _, names in os.walk(root, followlinks=False) for name in names)
    else:
        continue
    for file in files:
        if file.is_symlink():
            continue
        try:
            with file.open("rb") as f:
                prefix = f.read(4096)
        except (OSError, ValueError) as exc:
            problems.append(f"unreadable file {file}: {exc}")
            continue
        files_checked += 1
        if prefix.startswith(b"#!") and file.stat().st_mode & 0o111:
            line = prefix.split(b"\n", 1)[0].decode("utf-8", "replace")
            if re.search(r"(?:^|[/\s])(?:ba|da|z|k)sh(?:\s|$)", line) or re.search(r"\benv\s+.*\bbash\b", line):
                problems.append(f"unsupported script interpreter {file}: {line}")
        if not prefix.startswith(b"\x7fELF"):
            continue
        if prefix[16:18] == b"\x01\x00":
            continue  # ET_REL: startup objects for linking, never executed
        info = subprocess.run([a.readelf, "-lWd", str(file)], text=True, capture_output=True)
        if info.returncode:
            problems.append(f"readelf failed: {file}: {info.stderr.strip()}")
            continue
        interp = re.search(r"Requesting program interpreter:\s*([^\]]+)", info.stdout)
        if interp and "musl" not in interp.group(1):
            problems.append(f"non-musl interpreter: {file}: {interp.group(1)}")
        for needed in re.findall(r"Shared library: \[([^\]]+)\]", info.stdout):
            if re.match(r"(?:libstdc\+\+|libgcc_s|ld-linux|libc\.so\.6|libpthread\.so\.0)", needed):
                problems.append(f"forbidden ELF dependency: {file}: {needed}")
        if not interp and "DYNAMIC" not in info.stdout and str(file) not in a.reviewed_static:
            static.append(str(file))
for item in static:
    problems.append("static ELF requires independent provenance audit: " + item)
for problem in problems:
    print("FAIL:", problem, file=sys.stderr)
print(f"Checked {len(paths)} store paths and {files_checked} regular files; {len(problems)} findings.")
print("This preflight cannot prove script semantics or identify all renamed GNU code.")
sys.exit(1 if problems else 0)
