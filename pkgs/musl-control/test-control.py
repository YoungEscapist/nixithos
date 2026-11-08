#!/usr/bin/env python3
"""Isolated BusyBox ash CLI tests. switch tests require root + chroot."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

BUSYBOX = None
DINIT = None


class ControlTests(unittest.TestCase):
    def setUp(self):
        if os.geteuid() != 0:
            self.skipTest("chroot fixtures require root")
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for directory in ["bin", "etc/unit-runtime", "run", "nix/store/old/etc/dinit.d", "nix/store/new/etc/dinit.d", "nix/var/nix/profiles", "dev"]:
            (self.root / directory).mkdir(parents=True)
        shutil.copy2(BUSYBOX, self.root / "bin/busybox")
        (self.root / "bin/ash").symlink_to("busybox")
        (self.root / "dev/null").touch()
        replacements = {"shell": "/bin/ash", "busybox": "/bin/busybox", "dinitctl": "/bin/dinitctl", "dinitcheck": "/bin/dinit-check", "shutdown": "/bin/shutdown"}
        text = Path(__file__).with_name("nixith.sh").read_text()
        for key, value in replacements.items():
            text = text.replace("@" + key + "@", value)
        self.write("bin/nixith", text, 0o755)
        self.write("bin/dinit-check", '#!/bin/ash\n[ ! -e /run/fail-validation ]\n', 0o755)
        self.write("bin/dinitctl", '''#!/bin/ash
printf '%s\\n' "$*" >> /run/control.log
if [ "$2" = status ]; then printf 'Activation: start due to dependent(s)\\n'; fi
if [ -e /run/fail-start ] && [ "$2" = start ] && [ "$3" = boot ]; then exit 1; fi
exit 0
''', 0o755)
        self.write("bin/shutdown", '#!/bin/ash\nprintf "%s\\n" "$*" > /run/shutdown.log\n', 0o755)
        for generation in ["old", "new"]:
            self.write(f"nix/store/{generation}/etc/nixith-musl", "1\n")
            self.write(f"nix/store/{generation}/etc/dinit.d/boot", "type = internal\n")
            self.write(f"nix/store/{generation}/etc/dinit.d/changed", generation)
            self.write(f"nix/store/{generation}/etc/dinit.d/__console", "unchanged")
            (self.root / f"nix/store/{generation}/etc/unit-runtime/services").mkdir(parents=True)
        self.write("nix/store/old/etc/dinit.d/removed", "old")
        (self.root / "etc/dinit.d").symlink_to("/nix/store/old/etc/dinit.d")
        (self.root / "etc/unit-runtime/services").symlink_to("/nix/store/old/etc/unit-runtime/services")
        (self.root / "run/current-system").symlink_to("/nix/store/old")
        (self.root / "nix/var/nix/profiles/system").symlink_to("/nix/store/old")
        (self.root / "nix/var/nix/profiles/system-previous").symlink_to("/nix/store/older")

    def write(self, path, text, mode=0o644):
        target = self.root / path
        target.write_text(text)
        target.chmod(mode)

    def run_control(self, *args):
        return subprocess.run(["chroot", str(self.root), "/bin/nixith", *args], text=True, capture_output=True)

    def test_switch_updates_links_and_lifecycle(self):
        result = self.run_control("switch", "/nix/store/new")
        self.assertEqual(result.returncode, 0, result.stderr)
        for link in ["run/current-system", "nix/var/nix/profiles/system"]:
            self.assertEqual(str((self.root / link).readlink()), "/nix/store/new")
        self.assertEqual(str((self.root / "nix/var/nix/profiles/system-previous").readlink()), "/nix/store/old")
        commands = (self.root / "run/control.log").read_text().splitlines()
        for command in ["--system stop boot", "--system stop --force changed", "--system reload changed", "--system stop --force removed", "--system unload removed", "--system reload boot", "--system start boot"]:
            self.assertIn(command, commands)
        self.assertLess(commands.index("--system start __console"), commands.index("--system stop boot"))
        self.assertLess(commands.index("--system reload boot"), commands.index("--system unload removed"))
        self.assertIn("--system release --no-wait __console", commands)
        self.assertFalse((self.root / "run/nixith-switch.lock").exists())

    def test_validation_failure_preserves_generation(self):
        self.write("run/fail-validation", "")
        result = self.run_control("switch", "/nix/store/new")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("validation", result.stderr)
        self.assertEqual(str((self.root / "run/current-system").readlink()), "/nix/store/old")
        self.assertEqual(str((self.root / "nix/var/nix/profiles/system-previous").readlink()), "/nix/store/older")
        self.assertFalse((self.root / "run/nixith-switch.lock").exists())

    def test_missing_or_incompatible_schema_preserves_profiles(self):
        marker = self.root / "nix/store/new/etc/nixith-musl"
        for schema in [None, "2\n", "invalid\n"]:
            if schema is None:
                marker.unlink()
            else:
                marker.write_text(schema)
            result = self.run_control("switch", "/nix/store/new")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("schema 1", result.stderr)
            for link in ["run/current-system", "nix/var/nix/profiles/system"]:
                self.assertEqual(str((self.root / link).readlink()), "/nix/store/old")
            self.assertEqual(str((self.root / "nix/var/nix/profiles/system-previous").readlink()), "/nix/store/older")
            self.assertFalse((self.root / "run/control.log").exists())
            self.assertFalse((self.root / "run/nixith-switch.lock").exists())

    def test_same_generation_preserves_rollback_root(self):
        result = self.run_control("switch", "/nix/store/old")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(str((self.root / "nix/var/nix/profiles/system-previous").readlink()), "/nix/store/older")

    def test_activation_failure_is_reported(self):
        self.write("run/fail-start", "")
        result = self.run_control("switch", "/nix/store/new")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("partially failed", result.stderr)
        self.assertIn("previous generation /nix/store/old", result.stderr)
        self.assertEqual(str((self.root / "nix/var/nix/profiles/system-previous").readlink()), "/nix/store/older")

    def test_lock_and_invalid_arguments(self):
        (self.root / "run/nixith-switch.lock").mkdir()
        result = self.run_control("switch", "/nix/store/new")
        self.assertIn("another switch", result.stderr)
        for args in [("start", "--bad"), ("start", "has space"), ("switch", "/nix/store/new;touch /run/injected"), ("reboot", "extra")]:
            self.assertNotEqual(self.run_control(*args).returncode, 0)
        self.assertFalse((self.root / "run/injected").exists())

    def test_native_client_failure_propagates(self):
        self.write("bin/dinitctl", "#!/bin/ash\nexit 7\n", 0o755)
        self.assertEqual(self.run_control("status", "some-service").returncode, 7)

    def test_native_dinit_caller_survives_and_removed_chain_unloads(self):
        if DINIT is None:
            self.skipTest("--dinit-dir not supplied")
        for binary in ["dinit", "dinitctl", "dinit-check"]:
            shutil.copy2(DINIT / binary, self.root / "bin" / binary)
        self.write("bin/console-runner", '''#!/bin/ash
while [ ! -f /run/trigger ]; do /bin/busybox sleep 0.02; done
/bin/nixith switch /nix/store/new > /run/switch-output 2>&1
printf '%s\\n' "$?" > /run/switch-result
exec /bin/busybox sleep 300
''', 0o755)
        for generation in ["old", "new"]:
            self.write(f"nix/store/{generation}/etc/dinit.d/__console", "type = process\ncommand = /bin/console-runner\n")
            self.write(f"nix/store/{generation}/changed", f"#!/bin/ash\nprintf {generation} > /run/changed-marker\nexec /bin/busybox sleep 300\n", 0o755)
            self.write(f"nix/store/{generation}/etc/dinit.d/changed", f"type = process\ncommand = /nix/store/{generation}/changed\n")
            deps = "waits-for: __console\nwaits-for: changed\n"
            if generation == "old":
                deps += "waits-for: removed\nwaits-for: a-removed-dependency\n"
            self.write(f"nix/store/{generation}/etc/dinit.d/boot", "type = internal\n" + deps)
        self.write("nix/store/old/etc/dinit.d/removed", "type = process\ncommand = /bin/busybox sleep 300\ndepends-on: a-removed-dependency\n")
        self.write("nix/store/old/etc/dinit.d/a-removed-dependency", "type = process\ncommand = /bin/busybox sleep 300\n")
        daemon_log = (self.root / "run/daemon.log").open("w")
        daemon = subprocess.Popen(["chroot", str(self.root), "/bin/dinit", "--user", "-p", "/run/dinitctl", "-d", "/etc/dinit.d", "boot"], stdout=daemon_log, stderr=subprocess.STDOUT)
        try:
            def ctl(*args):
                return subprocess.run(["chroot", str(self.root), "/bin/dinitctl", "--system", *args], text=True, capture_output=True, timeout=5)
            for _ in range(250):
                if (self.root / "run/dinitctl").exists() and ctl("is-started", "boot").returncode == 0:
                    break
                time.sleep(0.02)
            else:
                self.fail("native daemon did not start: " + (self.root / "run/daemon.log").read_text())
            before = ctl("status", "__console").stdout.split("Process ID:")[1].strip()
            self.write("run/trigger", "")
            for _ in range(500):
                if (self.root / "run/switch-result").exists():
                    break
                time.sleep(0.02)
            else:
                self.fail("caller did not survive switch: " + (self.root / "run/switch-output").read_text())
            output = (self.root / "run/switch-output").read_text()
            self.assertEqual((self.root / "run/switch-result").read_text().strip(), "0", output)
            self.assertEqual(ctl("status", "__console").stdout.split("Process ID:")[1].strip(), before)
            self.assertEqual((self.root / "run/changed-marker").read_text(), "new")
            self.assertEqual(str((self.root / "nix/var/nix/profiles/system-previous").readlink()), "/nix/store/old")
            self.assertNotIn("removed", ctl("list").stdout)
            self.assertIn("Activation: start due to dependent(s)", ctl("status", "__console").stdout)
        finally:
            try:
                subprocess.run(["chroot", str(self.root), "/bin/dinitctl", "--system", "shutdown"], capture_output=True, timeout=3)
            finally:
                try:
                    daemon.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    daemon.kill()
                    daemon.wait(timeout=3)
                daemon_log.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--busybox", type=Path, required=True, help="static target BusyBox executable")
    parser.add_argument("--dinit-dir", type=Path, help="directory containing static native dinit binaries")
    args, remaining = parser.parse_known_args()
    BUSYBOX = args.busybox
    DINIT = args.dinit_dir
    unittest.main(argv=[__file__, *remaining])
