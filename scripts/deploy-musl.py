#!/usr/bin/env python3
"""Audit and deploy a complete strict rootfs to an explicitly selected target.

This host tool copies files only: it does not partition disks, format filesystems,
mount devices, install bootloaders or make an existing machine boot this system.
"""
import argparse
from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile

MARKER = ".nixith-musl-deployment.json"
SCHEMA = "nixith-musl-deployment-v1"
FORBIDDEN_TARGETS = {"/", "/nix", "/home", "/root", "/etc", "/usr", "/var", "/tmp", "/run", "/dev", "/proc", "/sys", "/boot"}


def load_auditor():
    spec = importlib.util.spec_from_file_location("musl_audit", Path(__file__).with_name("audit-musl-closure.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def children_without_mounts(root):
    """Reject nested mounted filesystems before replacement can remove anything."""
    for directory, dirs, _ in os.walk(root, followlinks=False):
        for name in dirs:
            child = Path(directory) / name
            if not child.is_symlink() and os.path.ismount(child):
                raise ValueError(f"nested mount must be unmounted first: {child}")


def preflight(source, destination, allow_unmounted=False):
    source = Path(source).resolve(strict=True)
    given_destination = Path(destination).absolute()
    if given_destination.is_symlink():
        raise ValueError("target itself must not be a symlink")
    destination = given_destination.resolve(strict=True)
    if not source.is_dir() or not destination.is_dir():
        raise ValueError("source and target must both be existing directories")
    protected_tree = any(destination == Path(prefix) or Path(prefix) in destination.parents
                         for prefix in ("/nix/store", "/proc", "/sys", "/dev"))
    if str(destination) in FORBIDDEN_TARGETS or protected_tree:
        raise ValueError(f"refusing protected target: {destination}")
    if source == destination or source in destination.parents or destination in source.parents:
        raise ValueError("source and target must not contain one another")
    if not allow_unmounted and not os.path.ismount(destination):
        raise ValueError("target is not a mount point; use --allow-unmounted only for explicit image staging")
    marker = destination / MARKER
    lost_found = destination / "lost+found"
    harmless_lost_found = lost_found.is_dir() and not lost_found.is_symlink() and not any(lost_found.iterdir())
    entries = [entry for entry in destination.iterdir() if not (entry == lost_found and harmless_lost_found)]
    if entries:
        if marker.is_symlink() or not marker.is_file():
            raise ValueError("target must be empty or contain a regular strict deployment marker")
        try:
            old = json.loads(marker.read_text())
        except (OSError, ValueError) as exc:
            raise ValueError(f"invalid deployment marker: {exc}") from exc
        if not isinstance(old, dict) or old.get("schema") != SCHEMA:
            raise ValueError("unrecognized deployment marker")
    children_without_mounts(destination)
    if not (source / "init").is_file() or not (source / "nix/store").is_dir():
        raise ValueError("source must be a rootfs containing init and its embedded nix/store")
    if (source / MARKER).exists() or (source / MARKER).is_symlink():
        raise ValueError("source rootfs must not carry a deployment marker")
    for directory, dirs, files in os.walk(source, followlinks=False):
        for name in dirs + files:
            path = Path(directory) / name
            mode = path.lstat().st_mode
            if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode) or stat.S_ISLNK(mode)):
                raise ValueError(f"source contains unsupported special file: {path}")
    return source, destination


def preserve_ownership(source, destination):
    """copy2 preserves modes/timestamps/xattrs; root also preserves numeric owners."""
    if os.geteuid() != 0:
        return
    for directory, dirs, files in os.walk(source, followlinks=False):
        for name in [""] + dirs + files:
            path = Path(directory) / name
            copied = destination / path.relative_to(source)
            metadata = path.lstat()
            os.chown(copied, metadata.st_uid, metadata.st_gid, follow_symlinks=False)
            # chown may clear setuid/setgid. Restore mode after owner changes.
            if not path.is_symlink():
                os.chmod(copied, stat.S_IMODE(metadata.st_mode))


def remove_entry(path):
    if path.is_symlink() or not path.is_dir():
        path.unlink()
    else:
        shutil.rmtree(path)


def deploy(source, destination, *, dry_run=False, allow_unmounted=False):
    source, destination = preflight(source, destination, allow_unmounted)
    report = load_auditor().audit([str(source)], rootfs=source)
    if not report["ok"]:
        details = "; ".join(f"{item['code']}: {item.get('path', '')}: {item['detail']}" for item in report["findings"][:20])
        raise ValueError("strict rootfs audit failed: " + details)
    manifest = {"schema": SCHEMA, "sourceRootfs": str(source), "target": str(destination),
                "createdAt": datetime.now(timezone.utc).isoformat(),
                "storePaths": ["/nix/store/" + entry.name for entry in sorted((source / "nix/store").iterdir())],
                "auditCounts": report["counts"]}
    if dry_run:
        return {"dryRun": True, **manifest}
    staging = Path(tempfile.mkdtemp(prefix=".nixith-deploy-", dir=destination))
    replacing = False
    try:
        shutil.copytree(source, staging, symlinks=True, dirs_exist_ok=True, copy_function=shutil.copy2)
        preserve_ownership(source, staging)
        # A complete copy exists before any existing generation is removed.
        # Each top-level rename is atomic; whole-root replacement is not.
        children_without_mounts(destination)
        replacing = True
        for entry in destination.iterdir():
            if entry != staging and entry.name != "lost+found":
                remove_entry(entry)
        for entry in list(staging.iterdir()):
            os.replace(entry, destination / entry.name)
        with tempfile.NamedTemporaryFile("w", prefix=".nixith-manifest-", dir=destination, delete=False) as marker:
            marker.write(json.dumps(manifest, indent=2) + "\n")
            marker_name = Path(marker.name)
        os.replace(marker_name, destination / MARKER)
    except Exception as exc:
        if replacing:
            raise RuntimeError(f"deployment partially failed after replacement started; target requires inspection: {destination}: {exc}") from exc
        raise
    finally:
        if staging.exists():
            # Store directory permissions may be read only for non-root staging.
            for directory, dirs, _ in os.walk(staging, followlinks=False):
                os.chmod(directory, 0o700)
            shutil.rmtree(staging)
    return {"dryRun": False, **manifest}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rootfs", type=Path)
    parser.add_argument("target", type=Path)
    parser.add_argument("--dry-run", action="store_true", help="audit and print deployment plan without writing")
    parser.add_argument("--allow-unmounted", action="store_true", help="explicitly allow an unmounted image staging directory")
    args = parser.parse_args()
    try:
        result = deploy(args.rootfs, args.target, dry_run=args.dry_run, allow_unmounted=args.allow_unmounted)
    except (OSError, ValueError, RuntimeError, shutil.Error) as exc:
        print(f"deploy-musl: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
