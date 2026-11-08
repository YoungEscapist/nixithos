# Strict musl services

`services.nix` takes `{ lib, pkgs, runtime, services }` and returns a tree
containing `etc/dinit.d` and `etc/unit-runtime/services`. Link both directories
into `/etc` before starting dinit. `runtime` is the package built from
`default.nix`; `unit-runtime run NAME` executes the named wrapper.

`services` is an attribute set whose keys are service names (ASCII letters,
digits, `_`, `-`, `.`; first character alphanumeric or `_`; `boot` is reserved).
Every service requires `command`, a nonempty list of strings whose first item
is an absolute executable path. Arguments are passed literally, without shell
expansion. The executable and everything it invokes must itself be suitable for
the musl/BusyBox system; this generator cannot prove that property.

Optional fields:

- `type`: `process` (default) for a foreground process, or `scripted` for a
  command that must exit successfully before the service is considered started.
- `dependsOn`: hard dinit dependencies, started first and required to remain up.
- `after`: ordering only, if both services are starting. It does not start the
  other service. Both fields default to empty lists.
- `restart`: boolean, default `false`. For process services, `true` restarts
  without a retry limit; it is rejected for scripted services.
- `stopSignal`: `TERM` (default), `HUP`, `INT`, `KILL` or `QUIT`.
- `stopTimeout`: positive integer seconds (default 10) before dinit sends
  `KILL` to a process that has not stopped. The built-in console uses `HUP`.
- `environment`: string-valued attribute set; the wrapper starts with an empty
  environment and BusyBox `PATH`, then applies these entries. Values are stored
  in the Nix store and therefore must not contain secrets.
- `workingDirectory`: absolute path or null (default); failure to enter it
  causes the service to fail.
- `user`: username or numeric ID string, or null (default); dinit performs the
  identity change using its native `run-as` semantics.
- `logFile`: absolute path or null (default). Without it, output is shared with
  the console. With it, the service wrapper appends stdout and stderr to that
  file; its directory must exist and be writable by the service user.

The internal `boot` target has `waits-for` dependencies on every service, so it
starts them all, waits for their initial start attempts and stays up if an
individual service stops or fails. Explicit `dependsOn` relationships remain
hard dependencies. Process services receive dinit's normal stop signal and are
supervised directly after the wrapper's `exec`. Unsupported settings, missing
or self dependencies, and cycles combining `dependsOn` and `after` are errors.
No stop command or scripted-service rollback is currently supported.
