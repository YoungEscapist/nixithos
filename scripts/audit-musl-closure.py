#!/usr/bin/env python3
"""Independent, bounded runtime-closure inspection; Python stdlib only.

Exit 0 means these checks passed, not a proof of arbitrary program behaviour.
Build tools are deliberately outside the queried runtime closure.
"""
import argparse
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys


FORBIDDEN = re.compile(
    r"^(?:glibc|bash|bash-interactive|coreutils|coreutils-full|gnugrep|gnused|gawk|"
    r"findutils|gnutar|gzip|binutils|binutils-unwrapped|gcc|gcc-unwrapped|"
    r"gcc-wrapper|gcc-runtime|libgcc|libstdc\+\+|libgomp|libatomic|gnulib|"
    r"gnumake|diffutils|patch|gettext|gettext-minimal|gnupatch|gnutime|"
    r"gnutls|readline|gdb|gdbm|gmp|mpfr|mpc|wget|ncurses|libidn2|"
    r"libunistring|libiconv|libtasn1|libgcrypt|libgpg-error|gnupg|guile|"
    r"hello|bison|m4|gperf|make|texinfo|screen|which|util-linux)(?:-|$)"
)
GNU_NEEDED = re.compile(r"^(?:libc\.so\.6|libpthread\.so\.0|libdl\.so\.2|librt\.so\.1|libm\.so\.6|libresolv\.so\.2|lib(?:gcc_s|stdc\+\+|gomp|atomic|quadmath|ssp|gfortran|itm|asan|ubsan|tsan|lsan|idn2|unistring|iconv|tasn1|gcrypt|gpg-error|gnutls|readline|gdbm|gmp(?:xx)?|mpfr|mpc|bfd|opcodes|ctf|ncursesw?|tinfo|guile(?:-[0-9.]+)?)\.so.*)$")


def elf_metadata(path):
    """Read ELF program headers/dynamic strings without executing the file."""
    with open(path, "rb") as stream:
        ident = stream.read(16)
        if ident[:4] != b"\x7fELF":
            return None
        if ident[4] not in (1, 2) or ident[5] not in (1, 2):
            raise ValueError("unsupported ELF class or byte order")
        endian = "<" if ident[5] == 1 else ">"
        bits = ident[4]
        hdr_format = endian + ("HHIIIIIHHHHHH" if bits == 1 else "HHIQQQIHHHHHH")
        header = struct.unpack(hdr_format, stream.read(struct.calcsize(hdr_format)))
        phoff, phentsize, phnum = header[4], header[8], header[9]
        phformat = endian + ("IIIIIIII" if bits == 1 else "IIQQQQQQ")
        phsize = struct.calcsize(phformat)
        if (phnum and phentsize < phsize) or phnum > 65535:
            raise ValueError("invalid program header layout")
        size = os.fstat(stream.fileno()).st_size

        def read_at(offset, count):
            if offset < 0 or count < 0 or offset + count > size or count > 16 * 1024 * 1024:
                raise ValueError("ELF field outside file or inspection bound")
            stream.seek(offset)
            data = stream.read(count)
            if len(data) != count:
                raise ValueError("truncated ELF")
            return data

        if header[0] == 1:  # ET_REL, including loadable Linux kernel modules.
            if phnum:
                raise ValueError("relocatable ELF unexpectedly has program headers")
            shoff, shentsize, shnum, shstr = header[5], header[10], header[11], header[12]
            shformat = endian + ("IIIIIIIIII" if bits == 1 else "IIQQQQIIQQ")
            shsize = struct.calcsize(shformat)
            if not shoff or not shnum or shentsize < shsize or shstr >= shnum:
                raise ValueError("invalid relocatable ELF section header layout")
            for index in range(shnum):
                section = struct.unpack(shformat, read_at(shoff + index * shentsize, shsize))
                if section[1] != 8:  # SHT_NOBITS has no file-backed contents.
                    read_at(section[4], section[5])
            return {"kind": "relocatable", "interpreter": None, "needed": []}
        if header[0] not in (2, 3) or not phnum:
            raise ValueError("executable/shared ELF has no valid program headers")

        loads, dynamic, interpreter = [], None, None
        for index in range(phnum):
            ph = struct.unpack(phformat, read_at(phoff + index * phentsize, phsize))
            typ = ph[0]
            offset, vaddr, filesz = (ph[1], ph[2], ph[4]) if bits == 1 else (ph[2], ph[3], ph[5])
            if typ == 1:
                loads.append((vaddr, offset, filesz))
            elif typ == 2:
                dynamic = (offset, filesz)
            elif typ == 3:
                interpreter = read_at(offset, filesz).rstrip(b"\0").decode("utf-8", "replace")
        needed, strtab, strsize = [], None, None
        if dynamic:
            fmt = endian + ("iI" if bits == 1 else "qQ")
            width = struct.calcsize(fmt)
            data = read_at(*dynamic)
            for pos in range(0, len(data) - width + 1, width):
                tag, val = struct.unpack_from(fmt, data, pos)
                if tag == 0:
                    break
                if tag == 1:
                    needed.append(val)
                elif tag == 5:
                    strtab = val
                elif tag == 10:
                    strsize = val
        names = []
        if needed:
            if strtab is None or strsize is None:
                raise ValueError("DT_NEEDED without bounded string table")
            table = next((read_at(off + strtab - addr, strsize)
                          for addr, off, length in loads
                          if addr <= strtab and strtab + strsize <= addr + length), None)
            if table is None:
                raise ValueError("dynamic string table is not file backed")
            for offset in needed:
                if offset >= len(table) or b"\0" not in table[offset:]:
                    raise ValueError("invalid DT_NEEDED string")
                names.append(table[offset:].split(b"\0", 1)[0].decode("utf-8", "replace"))
        return {"kind": "shared" if header[0] == 3 else "executable", "interpreter": interpreter, "needed": names}


def audit(paths, max_files=1000000, rootfs=None, system_root=None):
    original_image = str(Path(rootfs or system_root).absolute()) if rootfs or system_root else None
    image = str(Path(original_image).resolve(strict=True)) if original_image else None
    roots = sorted({image if str(Path(p).absolute()) == original_image else str(Path(p).absolute()) for p in paths})
    virtual_links = []
    allowed_virtual = {"/dev/fd": "/proc/self/fd", "/dev/stdin": "/proc/self/fd/0",
                       "/dev/stdout": "/proc/self/fd/1", "/dev/stderr": "/proc/self/fd/2",
                       "/etc/mtab": "/proc/self/mounts", "/var/run": "/run", "/var/lock": "/run/lock"}
    findings, counts, elfs = [], {"files": 0, "symlinks": 0, "scripts": 0, "elfs": 0}, []
    libraries, requirements = set(), []

    def issue(code, path, detail):
        findings.append({"code": code, "path": str(path), "detail": detail})

    def contained(path):
        return any(path == root or path.startswith(root + os.sep) for root in roots)

    def logical(path):
        value = str(path)
        return value[len(image):] or "/" if image and (value == image or value.startswith(image + "/")) else value

    def mapped(path):
        if image and (rootfs or not (path in ("/nix", "/nix/store") or path.startswith("/nix/store/"))):
            return Path(image + path)
        return Path(path)

    def resolve(path):
        if not image:
            return Path(path).resolve(strict=True)
        # Resolve one component at a time in the target namespace. Never let
        # the host OS follow an absolute image symlink into host /bin or /lib.
        pending = logical(path).split("/")
        parts, followed = [], 0
        while pending:
            part = pending.pop(0)
            if part in ("", "."):
                continue
            if part == "..":
                if parts:
                    parts.pop()
                continue
            candidate = mapped("/" + "/".join(parts + [part]))
            if candidate.is_symlink():
                followed += 1
                if followed > 40:
                    raise OSError("too many target-namespace symlinks")
                target = os.readlink(candidate)
                if target.startswith("/"):
                    parts = []
                pending = target.split("/") + pending
            else:
                if not candidate.exists():
                    raise FileNotFoundError(str(candidate))
                parts.append(part)
        return mapped("/" + "/".join(parts))

    def interpreter_exists(interpreter):
        try:
            target = resolve(interpreter)
            return contained(str(target)) and target.is_file()
        except OSError:
            return False

    def inspect(path):
        counts["files"] += 1
        if counts["files"] > max_files:
            raise ValueError("file inspection limit exceeded")
        if path.is_symlink():
            counts["symlinks"] += 1
            alias_path = logical(path)
            embedded_alias = re.fullmatch(r"/nix/store/[a-z0-9]{32}-nixithos-musl-system(/.*)", alias_path)
            if embedded_alias:
                alias_path = embedded_alias[1]
            if image and allowed_virtual.get(alias_path) == os.readlink(path):
                virtual_links.append({"path": logical(path), "target": os.readlink(path)})
                return
            try:
                target = resolve(path)
            except (OSError, RuntimeError) as exc:
                issue("broken-symlink", path, str(exc))
                return
            if not contained(str(target)):
                issue("symlink-outside-closure", path, str(target))
            elif target.is_file():
                libraries.add(path.name)
            return
        if not path.is_file():
            return
        libraries.add(path.name)
        try:
            with path.open("rb") as stream:
                prefix = stream.read(4096)
            if prefix.startswith(b"#!"):
                counts["scripts"] += 1
                first = prefix.split(b"\n", 1)[0][2:].strip().decode("utf-8", "replace")
                interpreter = first.split()[0] if first else ""
                if "bash" in first or re.search(r"(?:^|/)env(?:\s|$)", first):
                    issue("disallowed-shebang", path, first)
                elif not interpreter.startswith("/") or (not image and not contained(interpreter)):
                    issue("unverified-shebang", path, first)
                elif not interpreter_exists(interpreter):
                    issue("missing-script-interpreter", path, interpreter)
            metadata = elf_metadata(path) if prefix.startswith(b"\x7fELF") else None
            if metadata:
                counts["elfs"] += 1
                elfs.append({"path": str(path), **metadata})
                interpreter = metadata["interpreter"]
                if interpreter and ("ld-musl-" not in interpreter or (not image and not contained(interpreter))):
                    issue("non-musl-interpreter", path, interpreter)
                elif interpreter and not interpreter_exists(interpreter):
                    issue("missing-elf-interpreter", path, interpreter)
                for name in metadata["needed"]:
                    if GNU_NEEDED.match(name):
                        issue("gnu-runtime-dependency", path, name)
                    requirements.append((path, name))
        except (OSError, ValueError, struct.error) as exc:
            issue("inspection-error", path, str(exc))

    for root in roots:
        name = re.sub(r"^[a-z0-9]{32}-", "", Path(root).name)
        if FORBIDDEN.match(name):
            issue("forbidden-store-package", root, name)
        if rootfs and root == image:
            for package in (Path(root) / "nix/store").glob("*"):
                name = re.sub(r"^[a-z0-9]{32}-", "", package.name)
                if FORBIDDEN.match(name):
                    issue("forbidden-store-package", package, name)
        if not Path(root).exists():
            issue("missing-root", root, "closure path does not exist")
            continue
        try:
            inspect(Path(root))
            if Path(root).is_dir() and not Path(root).is_symlink():
                for directory, dirs, files in os.walk(root, followlinks=False, onerror=lambda exc: issue("walk-error", root, str(exc))):
                    for entry in dirs + files:
                        inspect(Path(directory) / entry)
        except ValueError as exc:
            issue("inspection-limit", root, str(exc))
            break
    for path, name in requirements:
        if name not in libraries:
            issue("unresolved-needed", path, name)
    return {"ok": not findings, "policy": "strict-musl-no-gnu-runtime", "roots": roots,
            "counts": counts, "findings": findings, "elfs": elfs, "virtual_links": virtual_links,
            "limitations": ["DT_NEEDED presence is checked across the closure, not per-object loader search order.",
                            "dlopen paths, generated commands, embedded archives and arbitrary executable behaviour are not proven by this audit.",
                            "GNU implementation identity cannot be proved or excluded from renamed/static binary contents alone."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--root", help="store output; query its runtime closure with nix-store -qR")
    group.add_argument("--paths", type=Path, help="newline-delimited closure paths (also permits fixture directories)")
    group.add_argument("--rootfs", type=Path, help="unpacked rootfs; inspect its embedded store in the target namespace")
    parser.add_argument("--system-root", type=Path, help="map /bin etc. through this system skeleton, with store references on host")
    parser.add_argument("--json", action="store_true", help="emit machine-readable report")
    parser.add_argument("--max-files", type=int, default=1000000)
    args = parser.parse_args()
    try:
        if args.max_files < 1:
            raise ValueError("--max-files must be positive")
        if args.rootfs and args.system_root:
            raise ValueError("--rootfs and --system-root are mutually exclusive")
        paths = ([str(args.rootfs.absolute())] if args.rootfs else
                 subprocess.run(["nix-store", "-qR", args.root], check=True, text=True, capture_output=True).stdout.splitlines()
                 if args.root else args.paths.read_text().splitlines())
        paths = [p.strip() for p in paths if p.strip()]
        if not paths:
            raise ValueError("empty closure path list")
        if args.system_root and str(args.system_root.absolute()) not in paths:
            paths.append(str(args.system_root.absolute()))
        report = audit(paths, args.max_files, rootfs=args.rootfs, system_root=args.system_root)
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        report = {"ok": False, "findings": [{"code": "input-error", "detail": str(exc)}]}
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print("PASS" if report["ok"] else "FAIL")
        for item in report["findings"]:
            print(f"{item['code']}: {item.get('path', '')}: {item['detail']}")
        for limitation in report.get("limitations", []):
            print("Scope: " + limitation)
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
