# User-session systemd compatibility

Enable `nixithos.compat.systemd.enable = true;` for applications that use the
user-session `org.freedesktop.systemd1` D-Bus interface. GNOME enables it by
default, replacing its previous limited adapter. The system's init stays s6,
dinit, runit or OpenRC; this does not start systemd as PID 1.

Static units continue through the native user manager and the systemctl adapter.
Transient services and scopes use a small runtime behind the same D-Bus name.
The root user-manager allocates a private delegated cgroup v2 subtree before
dropping privileges. Its PAM monitor remains outside that subtree. A root-only
registry records the allocation for cleanup; privileged cleanup does not read
paths from user-writable state. Disabling the option leaves the previous user
manager behaviour in place.

## Implemented subset

- `StartTransientUnit` for plain `.service` and `.scope` names; modes `fail` and
  `replace` are accepted for uncontended jobs, while a loaded unit name is not
  replaced. A conflicting pending job is rejected; job cancellation/replacement
  is not implemented.
- Services: exactly one `ExecStart` command (`a(sasb)`), `Type=simple`, `exec` or
  `oneshot`, `Environment`, absolute `WorkingDirectory`, `RemainAfterExit`.
  Arguments are passed as an argv array, without implicit shell parsing.
- Scopes: existing PIDs belonging to the bus user. Kernel migration permissions
  must allow moving them from their current cgroup into the delegated subtree;
  arbitrary processes elsewhere on the host are not automatically accessible.
- Common properties: `Description`, `TimeoutStopUSec` (positive, up to 300s),
  `Slice` (`app.slice`, `background.slice`, `session.slice`), `AddRef` and
  `CollectMode` (`inactive`, `inactive-or-failed`).
- Start/stop/restart of transient services, stop of scopes, `KillUnit`, reset of
  failure state. Restarting scopes or reloading transient units is unsupported.
- Unit/Service/Scope properties, native and transient `ListUnits`, real pending
  job objects and `ListJobs`/`GetJob`, `GetUnitByPID` for transient units,
  `JobRemoved`, `UnitNew`/`UnitRemoved` and `PropertiesChanged`.
- References through `AddRef`, `Ref` and `Unref`; disconnection releases a
  client's references. Unreferenced terminal units are collected after a short
  delay. Failed units are retained unless reset or collected explicitly.

The exec handshake distinguishes an executable that actually started from a
forked child that failed to exec. Oneshot jobs finish after their command exits.
Nonzero exits and execution failures produce failed jobs/states; a stop deadline
forces cgroup termination and reports `timeout`. Stop and cleanup include
processes that created a new session, not just the original process group.
Pre-existing cgroups are never adopted by a failed creation request.

Manager environment updates and native `systemctl --user set-environment` files
are included when constructing transient service environments. Logs go to
`$XDG_RUNTIME_DIR/systemd-compat/logs/UNIT`; integration of these logs into the
journalctl adapter is not implemented yet.

## Deliberate boundaries

This is a user-session API, not a system-bus systemd manager. System-wide
transient services, polkit authorization for them, arbitrary slices, resource
controller delegation, sandbox properties, socket/timer transient units,
auxiliary units and other job modes are not implemented. Unsupported properties
(such as `MemoryMax`, `User`, `PrivateNetwork` or `Delegate`) return an explicit
D-Bus error; they are not accepted as successfully applied.

The existing `systemd-run` and `systemctl` CLI adapters have not been extended to
manage these transient records. Use D-Bus clients for this subset; CLI support
and wider application checks are follow-up work. This does not make every
systemd-dependent package compatible.

Validation:

```sh
nix-build -A tests.systemd-compat -A dinit.systemd-compat
nix-build -A tests.systemd-compat-elogind
```

The API probe runs as an ordinary user in a native user service, exercises both
transient and static units and checks actual PIDs/cgroups and D-Bus signals.
The elogind test checks real login/logout, native user services and switching
with the compatibility option enabled.
