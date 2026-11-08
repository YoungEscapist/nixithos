#!/usr/bin/env python3
"""Exercise the strict target over its real serial login, without a guest agent."""
import argparse
import importlib.util
import os
from pathlib import Path
import re
import select
import shlex
import subprocess
import time


class Console:
    def __init__(self, command, logfile):
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT, bufsize=0)
        self.log = open(logfile, "wb")
        self.buffer = ""
        self.index = 0

    def expect(self, pattern, timeout=60):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            match = re.search(pattern, self.buffer[self.index:])
            if match:
                self.index += match.end()
                return match
            ready, _, _ = select.select([self.process.stdout], [], [], min(1, end - time.monotonic()))
            if ready:
                data = os.read(self.process.stdout.fileno(), 65536)
                if not data:
                    raise RuntimeError(f"QEMU exited while waiting for {pattern!r}: {self.buffer[-2500:]}")
                self.log.write(data)
                self.log.flush()
                self.buffer += data.decode(errors="replace").replace("\r", "")
        raise TimeoutError(f"serial timeout for {pattern!r}: {self.buffer[-3500:]}")

    def send(self, line):
        self.process.stdin.write((line + "\n").encode())
        self.process.stdin.flush()

    def check(self, command):
        # Split marker in the echoed shell input, so only real execution matches.
        self.send(f"{command}; result=$?; printf '\\nMUSL_%s:%s\\n' RESULT \"$result\"")
        self.expect(r"\nMUSL_RESULT:(\d+)\n")
        status = re.findall(r"\nMUSL_RESULT:(\d+)\n", self.buffer[:self.index])[-1]
        if status != "0":
            raise AssertionError(f"guest command failed ({status}): {command}\n{self.buffer[-3000:]}")

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.log.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--qemu", required=True)
    parser.add_argument("--kernel")
    parser.add_argument("--initrd")
    parser.add_argument("--next-system")
    parser.add_argument("--disk")
    parser.add_argument("--bootloader", action="store_true")
    parser.add_argument("--firmware")
    parser.add_argument("--reboot-check", action="store_true")
    parser.add_argument("--native-nix", action="store_true")
    parser.add_argument("--busybox-store")
    parser.add_argument("--tls-cache-source")
    parser.add_argument("--host-nix")
    parser.add_argument("--host-openssl")
    parser.add_argument("--log", required=True)
    args = parser.parse_args()
    if args.reboot_check and not args.disk:
        parser.error("--reboot-check requires --disk")
    if args.native_nix and not args.busybox_store:
        parser.error("--native-nix requires --busybox-store")
    if args.tls_cache_source and not (args.native_nix and args.host_nix and args.host_openssl):
        parser.error("TLS cache requires --native-nix, --host-nix and --host-openssl")
    cmd = [args.qemu, "-enable-kvm", "-m", "512", "-smp", "2", "-nographic",
           "-monitor", "none", "-serial", "stdio", "-no-reboot",
           "-netdev", "user,id=net0", "-device", "virtio-net-pci,netdev=net0"]
    if args.firmware:
        cmd += ["-machine", "q35", "-bios", args.firmware]
    if not args.bootloader:
        cmd += ["-kernel", args.kernel, "-initrd", args.initrd,
                "-append", "console=ttyS0 rdinit=/init panic=1 loglevel=3" +
                (" root=/dev/vda rootfstype=ext4" if args.disk else "")]
    if args.disk:
        cmd += ["-drive", f"file={args.disk},format=raw,if=virtio"]
    cache = None
    if args.tls_cache_source:
        spec = importlib.util.spec_from_file_location("musl_native_cache", Path(__file__).with_name("musl-native-cache.py"))
        cache_module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cache_module)
        cache = cache_module.TLSCache(args.host_nix, args.host_openssl, args.tls_cache_source)
        cache.__enter__()
    try:
        console = Console(cmd, args.log)
    except BaseException:
        if cache:
            cache.close()
        raise
    try:
        console.expect(r"login: ")
        console.send("root")
        console.expect(r"# ")
        console.check("test \"$(cat /proc/1/comm)\" = dinit")
        console.check("test \"$(readlink -f /bin/sh)\" = \"$(readlink -f /bin/busybox)\"")
        console.check("test ! -e /bin/bash && test -e /dev/fd/0")
        console.check("ip -4 addr show eth0 | grep -q 'inet 10.0.2.'")
        console.check("ping -c 1 -W 3 10.0.2.2 >/dev/null")
        console.check("nixith services && nixith status boot | grep -q STARTED")
        if args.native_nix:
            console.check("nix --version && test \"$(nix-instantiate --eval --expr '6 * 7')\" = 42")
            console.check("test -r /nix/var/nix/.image-registration && test -r /etc/ssl/certs/ca-certificates.crt")
            expression = ('builtins.derivation { name = "strict-musl-smoke"; system = builtins.currentSystem; '
                          'builder = (builtins.storePath "' + args.busybox_store + '") + "/bin/ash"; '
                          'args = [ "-c" "printf pure-musl > $out" ]; }')
            console.check("printf '%s\\n' " + shlex.quote(expression) + " > /root/smoke.nix")
            console.check("built=$(nix-build --no-out-link /root/smoke.nix) && test \"$(cat \"$built\")\" = pure-musl")
            console.check("nix-store -q --hash \"$built\" && nix-store --verify-path \"$built\"")
            console.check("nix-store --generate-binary-cache-key strict-musl-test /root/cache.secret /root/cache.pub")
            console.check("nix store sign --key-file /root/cache.secret \"$built\" && nix copy --to file:///var/lib/nix-cache \"$built\"")
            console.check("nix-store --delete \"$built\" && test ! -e \"$built\"")
            console.check("nix-store -r \"$built\" --option substituters file:///var/lib/nix-cache --option trusted-public-keys \"$(cat /root/cache.pub)\" --option require-sigs true && test \"$(cat \"$built\")\" = pure-musl")
            if cache:
                cache.guest_check(console)
                print("PASS: HTTPS cache, certificate verification, unsigned/wrong-key rejection, signed substitution")
        if args.next_system:
            console.check("test \"$(cat /run/token)\" = generation-one && test -f /run/second")
            console.check("nixith status failed | grep -q STOPPED")
            console.check("sleep 3; test \"$(cat /run/restarts)\" -ge 2")
            console.check("nixith stop removed && nixith status removed | grep -q STOPPED")
            console.check("nixith start removed && nixith restart removed")
            console.check(f"nixith switch {args.next_system}")
            console.check("test \"$(cat /run/token)\" = generation-two")
            console.check("nixith status added | grep -q STARTED")
            console.check("! nixith status removed")
            console.check(f"test \"$(readlink -f /run/current-system)\" = {args.next_system}")
            console.check(f"test \"$(readlink -f /nix/var/nix/profiles/system)\" = {args.next_system}")
        if args.disk:
            console.check("echo persistent-musl > /root/persistence; sync")
        console.send("nixith poweroff")
        console.expect(r"Power down|reboot: Power down", timeout=80)
        console.process.wait(timeout=10)
        if console.process.returncode:
            raise AssertionError(f"QEMU poweroff exit {console.process.returncode}")
        print("PASS: musl boot, login, BusyBox, DHCP, service lifecycle, shutdown" +
              (", dependency/failure/restart/generation switch" if args.next_system else ""))
    finally:
        console.close()
        if cache:
            cache.close()
    if args.reboot_check:
        console = Console(cmd, args.log + ".second-boot")
        try:
            console.expect(r"login: ")
            console.send("root")
            console.expect(r"# ")
            console.check("test \"$(cat /root/persistence)\" = persistent-musl")
            console.check("test \"$(cat /proc/1/comm)\" = dinit")
            console.check("ping -c 1 -W 3 10.0.2.2 >/dev/null")
            if args.native_nix:
                console.check("test \"$(nix-instantiate --eval --expr '6 * 7')\" = 42")
            if args.next_system:
                console.check("test \"$(cat /run/token)\" = generation-two")
                console.check(f"test \"$(readlink -f /run/current-system)\" = {args.next_system}")
                console.check("nixith status added | grep -q STARTED")
                console.check("! nixith status removed")
            console.send("nixith poweroff")
            console.expect(r"reboot: Power down", timeout=80)
            console.process.wait(timeout=10)
            if console.process.returncode:
                raise AssertionError(f"second QEMU poweroff exit {console.process.returncode}")
            print("PASS: ext4 data and selected generation persist across a cold boot")
        finally:
            console.close()


if __name__ == "__main__":
    main()
