#!/usr/bin/env python3
"""Host-only regression fixtures; no Nix build or target execution needed."""
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("audit", Path(__file__).parents[2] / "scripts/audit-musl-closure.py")
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


def elf(interpreter=None, needed=()):
    """Small ELF64 with real program/dynamic headers and no machine code."""
    data = bytearray(4096)
    ident = b"\x7fELF\x02\x01\x01" + b"\0" * 9
    data[:64] = ident + struct.pack("<HHIQQQIHHHHHH", 2, 62, 1, 0, 64, 0, 0, 64, 56, 3, 0, 0, 0)
    data[64:120] = struct.pack("<IIQQQQQQ", 1, 4, 0, 0x400000, 0, 4096, 4096, 4096)
    if interpreter:
        raw = interpreter.encode() + b"\0"
        data[512:512+len(raw)] = raw
        data[120:176] = struct.pack("<IIQQQQQQ", 3, 4, 512, 0x400200, 0, len(raw), len(raw), 1)
    strings = b"\0"
    dynamic = []
    for name in needed:
        dynamic.append((1, len(strings)))
        strings += name.encode() + b"\0"
    data[1024:1024+len(strings)] = strings
    dynamic += [(5, 0x400400), (10, len(strings)), (0, 0)]
    raw = b"".join(struct.pack("<qQ", *item) for item in dynamic)
    data[2048:2048+len(raw)] = raw
    data[176:232] = struct.pack("<IIQQQQQQ", 2, 4, 2048, 0x400800, 0, len(raw), len(raw), 8)
    return data


class AuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "runtime"
        self.root.mkdir()

    def report(self):
        return audit.audit([str(self.root)])

    def codes(self):
        return {item["code"] for item in self.report()["findings"]}

    def test_static_elf_and_store_shebang_pass(self):
        (self.root / "ash").write_bytes(elf())
        (self.root / "script").write_text(f"#!{self.root}/ash\nexit 0\n")
        (self.root / "sh").symlink_to("ash")
        self.assertTrue(self.report()["ok"])
        self.assertEqual(self.report()["counts"]["elfs"], 1)

    def test_bash_env_and_missing_shebangs_fail(self):
        for name, shebang in [("bash", "/bin/bash"), ("env", "/usr/bin/env sh"), ("missing", f"{self.root}/missing-ash")]:
            (self.root / name).write_text(f"#!{shebang}\n")
        self.assertEqual(self.codes(), {"disallowed-shebang", "missing-script-interpreter"})

    def test_glibc_and_gnu_runtime_needed_fail(self):
        (self.root / "app").write_bytes(elf("/lib64/ld-linux-x86-64.so.2", ["libc.so.6", "libstdc++.so.6", "libgcc_s.so.1"]))
        self.assertTrue({"non-musl-interpreter", "gnu-runtime-dependency", "unresolved-needed"} <= self.codes())
        self.assertEqual(audit.elf_metadata(self.root / "app")["needed"], ["libc.so.6", "libstdc++.so.6", "libgcc_s.so.1"])

    def test_musl_dynamic_fixture_passes(self):
        loader = self.root / "ld-musl-x86_64.so.1"
        loader.write_bytes(elf())
        (self.root / "app").write_bytes(elf(str(loader), [loader.name]))
        self.assertTrue(self.report()["ok"])

    def test_escaping_and_broken_symlinks_fail(self):
        outside = Path(self.temp.name) / "outside"
        outside.write_text("x")
        (self.root / "escape").symlink_to(outside)
        (self.root / "broken").symlink_to("missing")
        self.assertEqual(self.codes(), {"symlink-outside-closure", "broken-symlink"})

    def test_forbidden_name_boundary(self):
        bad = Path(self.temp.name) / ("a" * 32 + "-gcc-14.0-lib")
        bad.mkdir()
        self.assertFalse(audit.audit([str(bad)])["ok"])
        safe = Path(self.temp.name) / ("a" * 32 + "-not-bash-1.0")
        safe.mkdir()
        self.assertTrue(audit.audit([str(safe)])["ok"])

    def test_known_gnu_libraries_and_tools_package_boundaries(self):
        for name in ["ncurses", "libidn2", "libunistring", "libiconv", "libtasn1", "libgcrypt", "libgpg-error", "gnupg", "guile", "hello", "bison", "m4", "gperf", "make", "gnumake", "texinfo", "screen", "which"]:
            self.assertTrue(audit.FORBIDDEN.match(name + "-1.0"), name)
        for name in ["busybox-1.37", "musl-1.2", "ncursesish-1.0", "libidn20-1.0", "not-libiconv-1.0", "screening-tool-1.0", "musl-hello-service"]:
            self.assertFalse(audit.FORBIDDEN.match(name), name)
        for name in ["libidn2.so.0", "libunistring.so.5", "libgpg-error.so.0", "libncursesw.so.6", "libguile-3.0.so.1"]:
            self.assertTrue(audit.GNU_NEEDED.match(name), name)
        for name in ["libc.musl-x86_64.so.1", "libc++.so.1", "libnot-readline.so.1"]:
            self.assertFalse(audit.GNU_NEEDED.match(name), name)

    def test_truncated_elf_fails(self):
        (self.root / "broken").write_bytes(b"\x7fELF\x02\x01\x01" + b"\0" * 10)
        self.assertIn("inspection-error", self.codes())

    def test_bounded_scan_fails_closed(self):
        (self.root / "file").touch()
        report = audit.audit([str(self.root)], max_files=1)
        self.assertFalse(report["ok"])
        self.assertEqual(report["findings"][0]["code"], "inspection-limit")

    def test_rootfs_maps_absolute_links_without_host_interpreters(self):
        package = self.root / "nix/store" / ("a" * 32 + "-busybox")
        package.mkdir(parents=True)
        (package / "busybox").write_bytes(elf())
        (self.root / "bin").mkdir()
        (self.root / "bin/sh").symlink_to("/nix/store/" + package.name + "/busybox")
        (self.root / "init").write_text("#!/bin/sh\nexit 0\n")
        (self.root / "dev").mkdir()
        (self.root / "dev/fd").symlink_to("/proc/self/fd")
        report = audit.audit([str(self.root)], rootfs=self.root)
        self.assertTrue(report["ok"], report["findings"])
        self.assertEqual(report["virtual_links"], [{"path": "/dev/fd", "target": "/proc/self/fd"}])
        (self.root / "init").write_text("#!/bin/bash\n")
        self.assertFalse(audit.audit([str(self.root)], rootfs=self.root)["ok"])
        (self.root / "init").write_text("#!/usr/bin/python3\n")
        report = audit.audit([str(self.root)], rootfs=self.root)
        self.assertIn("missing-script-interpreter", {x["code"] for x in report["findings"]})

    def test_rootfs_checks_embedded_store_names(self):
        package = self.root / "nix/store" / ("a" * 32 + "-bash-5.0")
        package.mkdir(parents=True)
        report = audit.audit([str(self.root)], rootfs=self.root)
        self.assertFalse(report["ok"])
        self.assertEqual(report["findings"][0]["code"], "forbidden-store-package")

    def test_system_root_maps_shell_to_host_closure(self):
        # Fixture host path stands in for a host store output.
        # /bin/sh is mapped into the skeleton, then its absolute target is
        # also mapped: a host executable must not make a missing image pass.
        (self.root / "init").write_text("#!/bin/sh\n")
        report = audit.audit([str(self.root)], system_root=self.root)
        self.assertFalse(report["ok"])

    def test_relocatable_kernel_module_and_malformed_sections(self):
        ident = b"\x7fELF\x02\x01\x01" + b"\0" * 9
        header = ident + struct.pack("<HHIQQQIHHHHHH", 1, 62, 1, 0, 0, 64, 0, 64, 0, 0, 64, 1, 0)
        module = self.root / "virtio.ko"
        module.write_bytes(header + b"\0" * 64)
        self.assertTrue(self.report()["ok"])
        self.assertEqual(audit.elf_metadata(module)["kind"], "relocatable")
        module.write_bytes(header)
        self.assertIn("inspection-error", self.codes())

    def test_embedded_system_skeleton_virtual_alias(self):
        skeleton = self.root / "nix/store" / ("a" * 32 + "-nixithos-musl-system")
        (skeleton / "dev").mkdir(parents=True)
        (skeleton / "var").mkdir()
        (skeleton / "dev/fd").symlink_to("/proc/self/fd")
        (skeleton / "var/lock").symlink_to("/run/lock")
        report = audit.audit([str(self.root)], rootfs=self.root)
        self.assertTrue(report["ok"], report["findings"])
        self.assertEqual(len(report["virtual_links"]), 2)


if __name__ == "__main__":
    unittest.main()
