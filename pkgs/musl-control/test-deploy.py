#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import stat
import tempfile
import unittest


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


ROOT = Path(__file__).parents[2]
deploy = module("deploy", ROOT / "scripts/deploy-musl.py")
fixtures = module("fixtures", Path(__file__).with_name("test-audit.py"))


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.source = Path(self.temp.name) / "source rootfs"
        self.target = Path(self.temp.name) / "target root"
        self.source.mkdir()
        self.target.mkdir()
        package = self.source / "nix/store" / ("a" * 32 + "-busybox")
        package.mkdir(parents=True)
        binary = package / "busybox"
        binary.write_bytes(fixtures.elf())
        binary.chmod(0o755)
        (self.source / "bin").mkdir()
        (self.source / "bin/sh").symlink_to("/nix/store/" + package.name + "/busybox")
        (self.source / "init").write_text("#!/bin/sh\nexit 0\n")
        (self.source / "init").chmod(0o751)

    def install(self, **kwargs):
        return deploy.deploy(self.source, self.target, allow_unmounted=True, **kwargs)

    def test_dry_run_audits_without_writes(self):
        result = self.install(dry_run=True)
        self.assertTrue(result["dryRun"])
        self.assertEqual(list(self.target.iterdir()), [])

    def test_copy_preserves_symlinks_modes_and_manifest(self):
        self.install()
        self.assertEqual((self.target / "bin/sh").readlink(), (self.source / "bin/sh").readlink())
        self.assertEqual(stat.S_IMODE((self.target / "init").stat().st_mode), 0o751)
        marker = json.loads((self.target / deploy.MARKER).read_text())
        self.assertEqual(marker["schema"], deploy.SCHEMA)
        self.assertEqual(len(marker["storePaths"]), 1)

    def test_unmarked_target_and_symlink_target_refused(self):
        (self.target / "important").write_text("keep")
        with self.assertRaisesRegex(ValueError, "empty"):
            self.install()
        self.assertEqual((self.target / "important").read_text(), "keep")
        link = Path(self.temp.name) / "link"
        link.symlink_to(self.target)
        with self.assertRaisesRegex(ValueError, "symlink"):
            deploy.deploy(self.source, link, allow_unmounted=True)

    def test_upgrade_unlinks_hostile_destination_link(self):
        self.install()
        outside = Path(self.temp.name) / "outside"
        outside.mkdir()
        (outside / "keep").write_text("untouched")
        (self.target / "hostile").symlink_to(outside)
        (self.target / "stale").write_text("remove")
        self.install()
        self.assertEqual((outside / "keep").read_text(), "untouched")
        self.assertFalse((self.target / "hostile").exists())
        self.assertFalse((self.target / "stale").exists())

    def test_bad_audit_never_changes_target(self):
        (self.source / "bad").write_text("#!/bin/bash\n")
        with self.assertRaisesRegex(ValueError, "audit failed"):
            self.install()
        self.assertEqual(list(self.target.iterdir()), [])

    def test_protected_and_contained_targets_refused(self):
        for target in [Path("/"), self.source, self.source / "bin"]:
            with self.assertRaises(ValueError):
                deploy.preflight(self.source, target, allow_unmounted=True)

    def test_mount_requirement_and_empty_lost_found(self):
        with self.assertRaisesRegex(ValueError, "mount point"):
            deploy.preflight(self.source, self.target)
        (self.target / "lost+found").mkdir()
        self.install()
        self.assertTrue((self.target / "lost+found").is_dir())

    def test_source_marker_link_refused_before_writing(self):
        (self.source / deploy.MARKER).symlink_to("/etc/passwd")
        with self.assertRaisesRegex(ValueError, "source rootfs must not carry"):
            self.install()
        self.assertEqual(list(self.target.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
