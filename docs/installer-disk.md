# Encrypted and btrfs installations

The console installer offers LUKS2 encryption when erasing a disk on a UEFI
machine. It asks for a separate passphrase twice and shows LUKS2 in the final
disk summary. The EFI system partition stays unencrypted so the boot loader
can load the kernel and initrd. Unlock the system partition at boot.

The passphrase travels to the backend through an anonymous pipe. It is checked
before unmounting or erasing the disk, and is not placed in the environment,
command arguments, configuration or installation log. Automated callers use
`NI_ENCRYPT=1` and an already-open descriptor `NI_LUKS_FD` (at least 3).
An existing `/dev/mapper/cryptroot` must be closed by its owner before another
encrypted installation; the installer does not close it automatically.

Both ext4 and btrfs can be encrypted. Automatic encrypted BIOS layouts are not
supported. Manual partitioning keeps its existing workflow and hardware scan.
These additions currently apply to the console installer; the graphical
installer's encryption and subvolume workflow has not been validated here.

When automatically formatting btrfs the installer creates:

| Subvolume | Mount point |
| --- | --- |
| `@` | `/` |
| `@home` | `/home` |
| `@nix` | `/nix` |
| `@log` | `/var/log` |
| `@snapshots` | `/.snapshots` |

Each mount uses zstd compression and noatime. The generated configuration enables
`nixithos.snapshots`: before `nixith switch` or `nixith boot`, read-only snapshots
of `/` and `/home` are taken. The default retention is ten sets. Operations are
serialized with a lock; a failed snapshot warns and lets activation continue.

Use `nixith snapshots list`, `create`, `delete ID...` or `prune`. Configure
`nixithos.snapshots.paths`, `.directory` and `.keep` for an existing btrfs system.
The directory must already exist on the destination btrfs filesystem. Snapshot
names derived from configured paths must be distinct.

These are filesystem state snapshots. They exclude `/nix` and `/var/log`, do not
pin Nix store closures and are not an automatic filesystem restore mechanism.
Use Nix generations for software rollback and keep independent data backups.
Restoring the root subvolume requires a separate offline recovery procedure.

Validation:

```sh
nix-build -A tests.installer-disk  # actual ext4/btrfs and LUKS2 layouts in a VM
nix-build -A tests.snapshots      # snapshots, retention, concurrent operations, switch
nix-build -A tests.installer-ui   # encryption form in a PTY; no network/disk access
```

Validation on 2026-11-06: disk layouts passed (71.34 seconds), snapshots including
the switch hook passed (30.69 seconds), and the encryption form PTY test passed.
An actual ISO installation with LUKS2/btrfs/systemd-boot and dinit booted after
passphrase entry. The installed system's snapshot and switch checks passed after
fixing skipped ExecCondition starts (also covered by the dinit units suite).
Full installation evidence is in the separate VM handoff and logs; the automated
disk-layout test intentionally stops before installation.
