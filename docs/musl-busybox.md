# Strict musl and BusyBox profile

This is a separate minimal NixithOS profile. Its userspace runs on musl,
BusyBox ash and native dinit services. It does not turn the existing full
NixOS desktop configuration into a musl distribution. Existing NixithOS
profiles keep their own dependencies and implementation.

The strict runtime closure must exclude glibc, Bash, GNU command line tools
and GNU compiler runtime libraries, including libgcc and libstdc++. GNU
compilers and other GNU tools may run on the build host. They must not leak
into the deployed store closure. The Linux kernel is a separate boot
artifact, not a userspace libc consumer.

## Build and run

Run from the repository on a Nix build host:

```console
nix-build -A musl.vm -o result-musl-vm
./result-musl-vm/bin/run-nixithos-musl-vm
```

This starts a disposable QEMU machine with the root filesystem in its
initramfs. The example configuration explicitly permits passwordless root
login on its serial console. Omit `rootPasswordHash` in a custom configuration
to lock root login.

For a writable ext4 root, or a complete GPT disk with Limine:

```console
nix-build -A musl.diskVm -o result-musl-disk-vm
./result-musl-disk-vm/bin/run-nixithos-musl-disk-vm
nix-build -A musl.bootVm -o result-musl-boot-vm
./result-musl-boot-vm/bin/run-nixithos-musl-boot-vm
```

These launchers create writable disk copies in the current directory on first
use and reuse them on subsequent boots. `NIXITH_DISK=/absolute/path/disk.img`
selects a different copy. The standalone outputs are `musl.system`,
`musl.rootfs`, `musl.initrd`, `musl.diskImage` and `musl.bootDiskImage`.
The complete disk includes a kernel, initramfs, EFI partition and ext4 root;
the ext4-only image uses a separately supplied kernel and initramfs.

Flake equivalents include `nix build .#musl-vm`, `.#musl-initrd`,
`.#musl-disk`, `.#musl-boot-disk` and `.#musl-boot-vm`. A custom profile uses
the standalone constructor, with the same configuration interface as
[`examples/musl-minimal.nix`](../examples/musl-minimal.nix):

```console
nix-build -E '(import ./musl { configuration = import ./examples/musl-minimal.nix; }).vm'
```

This interface accepts its own small configuration schema. It does not
evaluate arbitrary NixOS modules or provide the full profile's desktop,
systemd compatibility, installer or hardware configuration interfaces.

## Service and control interface

Services use native dinit descriptions generated from typed Nix values:
an argv list, `process` or `scripted` type, dependencies, ordering,
environment, restart policy and optional working directory. Commands must
identify deployed executables. Runtime wrappers use BusyBox ash. They do
not translate systemd units or call the legacy Bash control programs.

`nixith help`, `version`, `services`, `status SERVICE`, `start SERVICE`,
`stop SERVICE`, `restart SERVICE`, `poweroff` and `reboot` are the minimal
control interface. Power actions use dinit's shutdown client so PID 1 can
stop services. `logs SERVICE` prints `/var/log/SERVICE.log` when explicitly
configured; console logging does not imply a retained log file.

`nixith switch /nix/store/HASH-SYSTEM` activates a generation already copied
into the runtime store. It requires the same schema-1 marker used at boot
and validates the new `boot` service graph using
`dinit-check`, publishes `/etc/dinit.d`, persistent
`/nix/var/nix/profiles/system` and `/run/current-system` symlinks,
stops and reloads changed services, removes old services, and starts the new
boot graph. Each symlink replacement is atomic. Service activation and the
links are not a transaction: a failed activation exits nonzero and
identifies the previous and requested generations. An operator must inspect
the result and explicitly switch to the previous generation to recover.
Services outside the new boot graph are not implicitly enabled. Boot selects
the persistent profile; a live switch also applies the generation's hostname
and `os-release`. It does not install bootloader entries, replace the running
kernel, refresh the runtime `/bin` applets, apply network setup or overwrite
user account files. This activation interface changes the service graph and
basic generation identity rather than reapplying every rootfs setting.

Runtime `nixith build` and `nixith install` exit nonzero with an explanation.
The default image has no native Nix evaluator, compiler or package download
client. Build on the host and deploy the resulting complete store
closure before switching. The existing full-profile installer is not a
strict-profile installer.

An optional native Nix package (Nix 2.28.8 built for musl with LLVM libc++,
compiler-rt and libunwind) is available behind the constructor's
`withNix = true` flag. Its build, closure audit, initial store registration,
sandboxed derivation build and signed substitution passed the checks listed
under verification. The flag stays opt-in and experimental: self-hosted
system builds, `nix-shell`, flake fetchers, the daemon/multi-user mode and
remote builds are untested. It does not change the `nixith` command's current
build/install behavior.

Native Nix does not itself prevent GNU or glibc packages from being built or
downloaded later. Audit each proposed generation's entire runtime closure
before activation. Successful switches retain one previous generation as the
Nix GC root `/nix/var/nix/profiles/system-previous`. Switching to the current
generation again preserves that rollback root. Root additional generations
explicitly if they are needed after Nix garbage collection.

## Deploy to a mounted filesystem

The host deployment tool installs a complete built rootfs, including its
embedded store closure, into an existing mounted filesystem:

```console
python3 scripts/deploy-musl.py /nix/store/HASH-ROOTFS /mnt/strict-root --dry-run
sudo python3 scripts/deploy-musl.py /nix/store/HASH-ROOTFS /mnt/strict-root
```

The target must already exist and be a mount point. `--allow-unmounted`
explicitly permits a directory for image staging or temporary fixture tests.
The tool rejects protected host directories, source/target containment,
symlink targets and nested mounts. The destination must be empty apart from
an empty `lost+found`, or carry the tool's recognized regular deployment
marker. It audits the complete source before writing. `--dry-run` performs
the same preflight and audit and prints a JSON plan without writes.

Copying preserves symlinks, file modes, timestamps and supported extended
attributes. Running as root also preserves numeric owners. The tool stages
the whole new copy before replacing existing content. A marked target is
replaced, including local configuration and user data; this is rootfs
deployment rather than a live service switch. Existing destination symlinks
are removed as links and never used as copy destinations. The final marker
records the source rootfs, deployed store paths and audit counts.

Replacement consists of multiple top-level renames and is not a filesystem
transaction. A storage failure during replacement reports a partial
deployment requiring inspection. Run it against an offline target. The tool
does not partition, format, mount, install a bootloader or change the host's
boot configuration. Arrange those boot prerequisites separately; `root=/dev/...`
selects the prepared root filesystem through the profile's initramfs.

## Independent runtime audit

Run on the host:

```console
python3 scripts/audit-musl-closure.py --root /nix/store/HASH-SYSTEM --system-root /nix/store/HASH-SYSTEM --json
python3 scripts/audit-musl-closure.py --rootfs /path/to/unpacked-rootfs --json
```

The auditor queries `nix-store -qR` and inspects every file in those runtime
outputs. Alternatively `--paths closure-paths.txt` accepts an already
queried newline-delimited closure. Python's standard library parses ELF
program headers, interpreters and `DT_NEEDED` entries; it does not execute
target binaries or require `readelf` in the runtime. The audit rejects:

- Known forbidden GNU/glibc package names, matched at package-name boundaries.
- Non-musl ELF interpreters and known GNU shared runtime dependencies.
- Missing shared library names and missing declared interpreters.
- Bash, `/usr/bin/env` and unverified external script interpreters.
- Broken symlinks, links escaping the supplied closure, malformed ELF files,
  inaccessible files and scans exceeding the file count bound.

Internal links are resolved and their target files are inspected through
the closure scan. Directory symlinks are not recursively followed; their
resolved targets must already belong to a scanned closure output. Errors
produce a nonzero exit and diagnostics, including in JSON mode.

`--system-root` resolves `/bin/sh` and other namespace paths through the
system skeleton, while `/nix/store` still refers to the host's queried
closure. `--rootfs` audits the embedded store and resolves all absolute
links and interpreters inside the unpacked image. It never accepts an
interpreter merely because it exists on the host. Exact conventional
virtual links for `/dev/fd`, `/dev/stdin`, `/dev/stdout`, `/dev/stderr`,
`/etc/mtab`, `/var/run` and `/var/lock` are recorded as runtime aliases.
Other links escaping the supplied namespace fail.

Passing these checks is evidence about this closure, not a proof of all
possible execution. A renamed or statically linked GNU implementation
cannot be identified reliably from package names or ELF headers alone.
The audit does not establish each object's exact loader search order,
inspect embedded archives, predict dynamically generated commands, or
prove arbitrary `dlopen` behaviour. The runtime derivations and service
commands must also be reviewed. A generated path list omitting actual
runtime references cannot establish closure completeness.

## Verification status

Evidence recorded on 2026-11-08/09:

- The original core QEMU integration passed boot/login, DHCP and gateway
  ping, service dependency ordering, failure reporting, automatic restart,
  start/stop/restart, changed/added/removed generation services, calling
  console survival, persistent-profile update and orderly shutdown. Output:
  `/nix/store/5sk970dsn0mf44i29q4yni9ancrvhdpr-nixithos-musl-integration`.
- The original ext4 two-boot test additionally passed persistent user data
  and selected-generation recovery after cold boot. Output:
  `/nix/store/3l903y4m5mm98i7cqp8xrg1b93gn9iz7-nixithos-musl-disk-integration`.
- The ext4 integration was repeated with the replacement Zig-built BusyBox
  and passed both lifecycle and cold-boot persistence checks. Output:
  `/nix/store/nk8idfkfry3v09m5v7ml90ayyp887j8b-nixithos-musl-disk-integration`.
- The complete Limine disk reached dinit login under both x86_64 BIOS and
  UEFI. This does not establish Secure Boot support or physical-hardware
  compatibility. These firmware results preceded the BusyBox replacement;
  repeat them for a final changed boot image.
- Both standalone-system and complete-rootfs guards rejected deliberate
  GNU hello/glibc inclusion. Successful image builds run the independent
  mandatory runtime audit.
- Host tests passed 14 auditor fixtures, eight deployment fixtures and six
  control fixtures. The control suite includes actual static dinit in a
  chroot, with the calling console surviving unchanged and a removed
  dependency chain unloaded. Deployment fixtures cover safe replacement,
  metadata, symlink handling and audit rejection before writes. Actual
  rootfs deployment dry-run passed without modifying its temporary target.

Reproduce the automated VM checks with `nix-build -A tests.musl` and
`nix-build -A tests.musl-disk`. Each successful output contains `passed` and
serial logs; the disk test also records the second boot. The initial two
outputs above used the earlier static GCC-built BusyBox, so they alone do
not validate the replacement's compiler runtime boundary.

Native Nix (`withNix = true`) was verified on 2026-11-10:

- `pkgs/musl-nix/audit.py` on the Nix output closure: 29 store paths, 301
  files, no findings; no GCC runtime, libstdc++ or glibc. The mandatory
  system and rootfs audits also pass with Nix included.
- `nix-build tests/musl-native.nix -A test` passed: evaluation, a sandboxed
  derivation built with the BusyBox shell, path verification, signing, copy
  to a local file cache, deletion and signed re-substitution, and evaluation
  again after a cold boot from the persistent store.
- The live-host HTTPS run (`tests/musl-vm.py --tls-cache-source ...`) passed:
  certificate verification, rejection of an unsigned cache and of a wrong
  key, then signed substitution over TLS.

Build-side deviations from nixpkgs: OpenSSL without the AF_ALG engine, boehm-gc
built with the libc++ toolchain, SQLite with a legacy SONAME and no Tcl
extension, `sys/syscall.h` force-included for libutil. Not covered: the
daemon, multi-user builds, remote builders, flakes over the network,
`nix-shell`, and substitution from cache.nixos.org itself.
Desktop parity, disk partitioning, bootloader generation
updates, full NixOS-module compatibility and self-hosted system builds are
not delivered by the tested minimal profile.
