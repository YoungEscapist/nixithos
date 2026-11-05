# Experimental Finit backend

Work starts from NixithOS main c3491f4. This branch adds `nixithos.init = "finit"`
with Finit 4.17 as PID 1 and its native service manager. It is not yet an
installer choice or part of the published ISO.

The first stage packages the released upstream tarball, generates native
Finit tasks and services from the existing unit compiler, and runs them through
`unit-runtime` and `unit-supervise`. User managers remain s6 trees. The Finit
control socket is reached by `finitctl`, which implements the subset of the
manager commands the shared runtime uses. Logs keep their existing s6-log
layout, so `journalctl` can read them.

The NixithOS stage 2, mount units, udev, gettys, random-seed handling and runtime
cgroups retain their existing responsibilities. Finit uses a separate empty
fstab and disables the overlapping optional plugins and its own cgroup manager.
Large ordering barriers are split to respect Finit 4.17's 192-byte condition
field as well as its 1024-byte configuration line limit. Services have stable generated names, recorded in `finit-names.tsv`.

Run the initial integration test with:

```sh
nix-build -A finit.smoke
```

The test boots a real VM, checks the executable of PID 1, the default target,
D-Bus and an ordinary service, waits for the boot marker to clear, checks the
reported system state, and powers the VM off through `systemctl`.

Initial validation on 2026-11-05: `finit.smoke` passed (36.32 seconds),
including native PID 1, D-Bus, a compiled NixOS service, `running` state and
normal VM poweroff. This establishes a bootable prototype; it does not yet
establish compatibility with the full unit test matrix.

Before this backend can be offered by the installer:

- Separate ordering, hard requirements and optional dependencies in Finit
  conditions. The initial graph conservatively waits for readiness/success;
  failed optional dependencies can currently hold back unrelated startup.
- Implement and test the full synchronous start/stop/restart contract,
  oneshot stop commands, readiness timeouts and restart limits.
- Implement live configuration reconciliation and test unchanged PIDs,
  changed services, removal, rollback and transaction locks. Live activation
  on a running Finit system currently rejects `switch`/`test`; use boot-only
  generations during development.
- Run unit semantics, login, user services, sandbox, hardening, timesync and
  bootloader/rollback tests, then an actual installation and desktop login.
- Add TUI/Calamares choices only once those checks establish the supported
  behaviour.

Upstream references for the pinned release:

- [Finit 4.17](https://github.com/finit-project/finit/releases/tag/4.17)
- [Services and readiness](https://github.com/finit-project/finit/blob/4.17/doc/config/services.md)
- [Task completion and remain semantics](https://github.com/finit-project/finit/blob/4.17/doc/config/task-and-run.md)
