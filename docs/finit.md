# Finit

`nixithos.init = "finit";` runs Finit 4.17 as PID 1 and service manager. It
is the fifth init system of NixithOS, next to s6, dinit, runit and OpenRC, and
runs the same units: `systemctl`, `journalctl`, the logs, the user managers
(s6 trees, as under runit and OpenRC) and `nixith` work the same way.

## How it is put together

- **The package** is the released upstream tarball. Finit's own mount,
  getty, hotplug, cgroup and urandom handling are switched off: stage 2,
  udev, the unit runtime and its cgroups do that, as for the other init
  systems. `/etc/finit.fstab` is empty.
- **The services** are written by the unit compiler (`unitc --init finit`,
  `emit_finit`) into the unit database: one `service` stanza for each process
  and one `task` for each oneshot, target, mount or socket, all in
  `finit/services.conf`, which `/etc/finit.conf` includes through
  `/run/units/.db`, the database of the configuration that runs. The
  processes of a service run under `unit-supervise`, as under dinit.
- **Dependencies.** Finit starts a stanza once all of its conditions are
  asserted. The states it asserts itself (`service/X/ready`,
  `task/X/success`) never come for a unit that fails, so they cannot stand
  for systemd's edges: a failing unit wanted by `multi-user.target` would
  hold back the boot for good. Each atom asserts a condition of its own
  instead, `usr/sHASH`, once it is done trying: a task once it has run, a
  service once it is ready or has exited (its `ready:` and `post:` scripts).
  What comes after it waits for that, whatever the outcome:

  | systemd | dinit | Finit stanza |
  |---|---|---|
  | `Requires=`, `BindsTo=` | depends-on | waits for it; does not run if it did not come up |
  | `Wants=` | waits-for | waits for it |
  | `After=` alone | after | waits for it if it is part of the boot |

  How each atom did is recorded in `/run/units/.finit-rc` by the same
  scripts: Finit drops `task/X/success` as soon as a task started by hand is
  halted again, and `service/X/ready` is in flux while Finit reads its
  configuration again. Long lists are split into barrier tasks, because a
  Finit 4.17 condition field holds 192 bytes.
- **Control.** `finitctl` answers what `dinitctl` is asked by `systemctl`, the
  runtime and `switch-to-configuration`: `list`, `status`, `start`, `stop`,
  `restart` (synchronous; `--no-wait` keeps Finit's asynchronous request),
  `rescan`. Starting an atom starts what it requires and wants first, and
  stopping one stops what requires it, as dinit does; the edges are in
  `finit-deps.tsv`. A task started is waited for until its run has ended.
- **Live switches.** `switch-to-configuration` stops what has to be stopped,
  activates, points `/run/units/.db` at the new database and has Finit read
  it again (`finitctl rescan`, which waits for the reload to settle): what
  is gone is stopped, what is new is started. Then it restarts what changed
  and starts what the new system wants, as under dinit. Conditions that
  link to Finit's reconf file stay asserted across the reload, so what
  depends on a unit is neither paused nor stopped by it.
- **Shutdown.** `systemctl poweroff`, `reboot` and `halt` go to `initctl`;
  Finit stops the services and runs `s6.init.finalCommands`. Ctrl-Alt-Del
  reboots, as with the other init systems (Finit by itself only asserts
  `sys/key/ctrlaltdel`; `/etc/finit.conf` has a task for it).

Two things about Finit 4.17 that the adapter works around:

- `initctl status` walks the services through one iterator in PID 1 shared
  by all clients, so two walks at a time take services from each other.
  `finitctl` takes its snapshots under a lock and takes one again when it
  lacks services.
- PID 1 renames itself `init` (`/proc/1/comm`); `/proc/1/exe` is the Finit
  binary.

## Tests

The same VM tests as for dinit run on Finit, plus two of its own:

```sh
nix-build -A finit.boot          # boot, services, socket activation, shutdown
nix-build -A finit.units         # unit semantics: dependencies, failures, sockets, timers…
nix-build -A finit.switch        # live switch and back
nix-build -A finit.smoke         # PID 1, D-Bus, a service, poweroff
nix-build -A finit.control       # finitctl: stop/start/restart, notify, try-restart
nix-build -A tests.init-change   # an installation s6 → dinit → runit → OpenRC → Finit → s6
```

and `finit.login`, `.elogind`, `.user-services`, `.sandbox`, `.hardening`,
`.timesync` and `.rollback-{systemd-boot,grub,limine}`.

Upstream references for the pinned release:

- [Finit 4.17](https://github.com/finit-project/finit/releases/tag/4.17)
- [Conditions](https://github.com/finit-project/finit/blob/4.17/doc/conditions.md)
- [Services and readiness](https://github.com/finit-project/finit/blob/4.17/doc/config/services.md)
- [Task completion and remain semantics](https://github.com/finit-project/finit/blob/4.17/doc/config/task-and-run.md)
