# Experimental Finit backend

Finit 4.17 is available as an **experimental** `nixithos.init = "finit"` choice
in the console installer and ISO. It runs as PID 1 with its native service
manager. The stable init systems remain the recommended choices.

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
nix-build -A finit.control
```

The test boots a real VM, checks the executable of PID 1, the default target,
D-Bus and an ordinary service, waits for the boot marker to clear, checks the
reported system state, and powers the VM off through `systemctl`.

Validation on 2026-11-07: `finit.smoke` passed (36.32 seconds),
including native PID 1, D-Bus, a compiled NixOS service, `running` state and
normal VM poweroff. `finit.boot` also passed its real-VM boot, service-control
and Nix-daemon socket-activation checks. Full unit semantics, installation and
desktop-login compatibility are still under validation.

The control adapter waits for stop completion and for Finit's native ready
condition on start. Synchronous restart is stop/wait/start/wait; `--no-wait`
keeps the native asynchronous request. Each wait is bounded at 90 seconds.
`finitctl list` parses the status snapshot in one jq process. The control VM
checks delayed ExecStop, notify readiness, PID replacement, asynchronous stop,
complete status enumeration and unknown-unit errors.

`systemctl try-restart` retains the existing supervisor and requests a process
restart through it. This keeps the native ready condition asserted: dropping
it while boot ordering tasks run can terminate those tasks and leave the boot
graph waiting indefinitely (observed with resolvconf's nscd restart hook).
The control test checks both a changed main PID and an unchanged supervisor PID.

Remaining work before recommending this backend for general use:

- Separate ordering, hard requirements and optional dependencies in Finit
  conditions. The initial graph conservatively waits for readiness/success;
  failed optional dependencies can currently hold back unrelated startup.
- Extend the tested long-running service controls to oneshot stop commands,
  failure propagation, per-unit readiness timeouts and restart limits. The
  adapter's fixed 90-second wait is an initial bound, not per-unit policy.
- Implement live configuration reconciliation and test unchanged PIDs,
  changed services, removal, rollback and transaction locks. Live activation
  on a running Finit system currently rejects `switch`/`test`; use boot-only
  generations during development.
- Run unit semantics, login, user services, sandbox, hardening, timesync and
  bootloader/rollback tests, then installation and desktop-login scenarios.
  Finit is exposed in the TUI only as an experimental option while these checks
  and live configuration reconciliation remain incomplete.

Upstream references for the pinned release:

- [Finit 4.17](https://github.com/finit-project/finit/releases/tag/4.17)
- [Services and readiness](https://github.com/finit-project/finit/blob/4.17/doc/config/services.md)
- [Task completion and remain semantics](https://github.com/finit-project/finit/blob/4.17/doc/config/task-and-run.md)
