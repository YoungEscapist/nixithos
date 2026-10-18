# Design

**English** · [Русский](ru/design.md)

## Name

The system calls itself NixithOS (`modules/branding.nix`): these are NixOS's
stock `system.nixos.distroName`/`distroId`/`vendorName`, so the name is seen
by `/etc/os-release` (`ID=nixithos`, `ID_LIKE=nixos`), the boot loader menus,
the console greeting and everything that reads os-release. The mark is in
`branding/`: a picture, the same in characters (`logo.txt`) and with colour
markers for fastfetch (`logo-fastfetch.txt`), for which the system provides
`/etc/xdg/fastfetch/config.jsonc`. `nixithos.branding.enable = false` brings
back the NixOS name.

## A layer on top of nixpkgs

The nixpkgs tree is not forked. `lib/nixpkgs.json` pins a revision, and the
NixOS modules are imported from it by path. `modules/module-list.nix` takes
the stock module list and splits it into three parts:

- **kept**: nearly all of them (services, users, networking, boot loaders…);
- **options only**: the modules that *are* the systemd integration
  (`system/boot/systemd.nix`, journald, logind, networkd, …). Other modules
  read and set their options, so the declarations stay and half of `config`
  is dropped. This is done without copying: the module is imported as a
  function, and only `options` and `imports` are taken from the result;
- **replaced entirely**: the scripted initrd (`stage-1`), taken from nixpkgs
  and moved onto eudev.

Our own modules live in `modules/` and provide an implementation where one is
needed.

Updating nixpkgs means changing the revision in `lib/nixpkgs.json` and
running the tests. If a module from the lists was renamed, the build stops
with a clear message.

## Boot

```
kernel → initrd (stage 1: eudev, root) → $toplevel/init (stage 2)
       → s6-linux-init → s6-svscan (PID 1) + rc.init
```

**Stage 2** (`modules/system/boot/stage-2-init.sh`) is the same script as in
NixOS: special file systems, `/nix/store` read-only, the activation script.
Then it sets the host name, creates `/etc/machine-id` and starts
`s6-linux-init` where NixOS starts systemd.

The base directory of s6-linux-init is created by `s6-linux-init-maker` at
build time and lives in the store. The store cannot hold FIFOs, so the two
FIFOs of its `/run` image (the logger and shutdownd) are cut out at build
time and created by stage 2 right before `exec`; s6-linux-init itself is
started with `-N` (do not remount `/run`) and copies the rest of the image
over it.

**rc.init** does three steps:

1. `s6-rc-init` on the `compiled-boot` database and `s6-rc -u change
   default`: booting with the full ordering.
2. `s6-rc-update` to the `compiled` database: not a single service is
   restarted (dependencies are only removed).
3. If something failed without being required by anyone, everything that
   was "after" it did not start in the first step. Now that ordering is no
   longer a dependency, it is started.

While booting is in progress, `/run/units/.booting` exists.

## Units → s6-rc

`modules/compat/units.nix` generates the unit directory with NixOS's stock
library (`nixos/lib/systemd-lib.nix`): units from modules, units from
`systemd.packages`, drop-ins, aliases, `.wants` directories. There is one
difference from NixOS: nothing is copied from the systemd package. The
standard targets and early services that systemd ships itself are defined in
`modules/compat/base-units.nix`.

`pkgs/unitc/unitc.py` reads that directory and writes:

| file | what it is |
|---|---|
| `source-boot/`, `source/` | s6-rc sources for the two databases |
| `unit-data/<unit>` | the unit's data: bash variables and functions for `unit-runtime` |
| `index.tsv` | unit → type, rank, s6-rc service names, what to start along with it |
| `ranks.tsv` | the rank of every s6-rc service |
| `switch.tsv` | hashes and flags for `switch-to-configuration` |
| `devices.tsv` | which units to start when a device appears |
| `manifest.json` | all of the above in one file |
| `report.txt` | everything that was ignored or simplified |

The s6-rc service name is the unit name without `.service` (`sshd`); other
types keep the full name (`multi-user.target`). Early services carry systemd
unit names (`systemd-udevd.service`) so that partial definitions from NixOS
modules and other units' `After=` land on them; on the s6 side they have
human names (`udevd`), set by `X-S6-Name=`.

Our own directives (all `X-…`, systemd ignores them):

- `X-S6-Name=` in `[Unit]`: the name on the s6 side;
- `X-Replace=yes` in `[Unit]`: the definition is complete, do not mix in the
  package's unit of the same name;
- `X-NotifyFd=N` in `[Service]`: the daemon reports readiness itself with
  the s6 protocol on descriptor N (`s6-socklog -d 3`, `dbus-daemon
  --print-address=3`);
- `X-Fsck=yes` in `[Mount]`: check the file system before mounting.

### What unit-runtime does

The `run` script of every service is one line: `unit-runtime run <data>`.
It:

1. clears the environment and builds the one the unit describes
   (`Environment=`, `EnvironmentFile=`, `HOME`/`USER` with `User=`);
2. checks `Condition*=`/`Assert*=`;
3. creates the cgroup `/sys/fs/cgroup/units/<name>` and applies limits
   (`MemoryMax=`, `TasksMax=`, …);
4. creates `RuntimeDirectory=` and its relatives, lays out
   `LoadCredential=`;
5. runs `ExecStartPre=`;
6. starts the main process through `setpriv`/`prlimit`/`nice` (user,
   groups, capabilities, `NoNewPrivileges=`, limits), passing sockets as
   `LISTEN_FDS`;
7. tells s6 the service is ready when systemd would consider it ready: right
   away (`simple`), on `READY=1` (`notify`; `unit-notify` listens), when the
   daemon has detached (`forking`), when the name has appeared on the bus
   (`dbus`), and only after `ExecStartPost=`. With `notify-reload` the
   notification socket lives for the whole run of the service: the daemon
   reports every reload there, and sshd also checks that the socket is
   there.

unitc parses command lines and `Environment=` the way systemd does: quotes
are removed in the middle of a word too (`-port="8888"` is `-port=8888`; the
cfssl module relies on this).

`finish` runs `ExecStopPost=`, kills what is left in the cgroup, removes the
directories and decides by `Restart=` whether to restart: exit code 125
tells s6-supervise "do not start again". `StartLimitBurst=` is counted here
too.

A long-running service's `ExecStop=` has nowhere to hang: s6 has no "before
stopping" hook. So such units get a oneshot `<name>-hooks` that depends on
the service; its `down` is the `ExecStop=`.

Every unit's state lives in `/run/units/<unit>/` (`state`, `result`).

The lines systemd writes to the journal about the unit itself ("Started …",
"Stopped …", "Reloaded …", "Failed with result …") the runtime writes to
`/run/units/<unit>/journal`; `journalctl -u` merges them with the service's
log by time. `OnFailure=` and `OnSuccess=` run on state changes: the listed
units are started with `systemctl --no-block start`.

The output of a oneshot job goes only to its directory
`/var/log/s6/<unit>/` (as with systemd: to the journal, not the screen); only
the line about a failure reaches the console.

`s6.logging.echoFailures` writes the tail of a failed unit's log to
`/dev/kmsg`, so it shows up on the console: for test VMs, where there is no
other place to read why.

### Sandbox

`PrivateTmp=`, `PrivateDevices=`, `PrivateNetwork=`, `PrivateIPC=`,
`ProtectHostname=`, `ProtectSystem=` (`yes`, `full`, `strict`),
`ProtectHome=` (`yes`, `read-only`, `tmpfs`), `ReadOnlyPaths=`,
`ReadWritePaths=`, `InaccessiblePaths=`, `BindPaths=`, `BindReadOnlyPaths=`,
`TemporaryFileSystem=`, `ProtectKernelTunables=`, `ProtectControlGroups=`
are really enforced. `unitc` collects the arguments in `U_SANDBOX`; for every
command of the unit (`ExecStartPre=`, `ExecStart=`, `ExecStop=`…) the
runtime puts a prefix before `setpriv`:

```
unshare --mount --propagation private [--net] [--uts] [--ipc] --
        unit-sandbox ARGUMENTS -- command…
```

`unit-sandbox` is bash: it makes the mounts in the new namespace and execs
the command. Devices: a private `/dev` on tmpfs with bound
`null zero full random urandom tty`, `pts`, `shm`. "Read-only" is
`mount -o remount,bind,ro` on every mount point under the path;
`ProtectSystem=strict` does that to all of them except `/dev`, `/proc`,
`/sys`, and `ReadWritePaths=` and the unit's directories
(`RuntimeDirectory=`, `StateDirectory=`, `CacheDirectory=`,
`LogsDirectory=`) make them writable again. `DynamicUser=yes` implies
`ProtectSystem=strict`, `ProtectHome=read-only` and `PrivateTmp=`, as in
systemd.

`ProtectKernelModules=`, `ProtectKernelLogs=`, `ProtectClock=` drop the
corresponding capabilities from the bounding set.

`RootDirectory=` (and `MountAPIVFS=`, `RootDirectoryStartOnly=`) is the same
`unit-sandbox` with `--root`: all paths of the directives
(`TemporaryFileSystem=`, `PrivateTmp=`, `ProtectSystem=`, the targets of
`BindPaths=`) are taken inside the root, the sources of binds on the host.
The `chroot` itself is done by `unit-chroot` after `setpriv`: for that moment
the process has CAP_SYS_CHROOT in its ambient set, then it is dropped. This
is how `tor.service`, for example, works.

What is missing: `SystemCallFilter=`, `RestrictAddressFamilies=`,
`MemoryDenyWriteExecute=`, `RestrictNamespaces=` and the rest of seccomp, as
well as `PrivateUsers=`, `ProtectProc=`, `RootImage=`; they stay in
`report.txt`. A path that does not exist is a warning, not a failure
(systemd fails).

### Ordering, requirements and failures

- `After=` is honoured only against units that will be started anyway (they
  are part of boot or pulled in by the unit itself), as in systemd, where
  ordering applies within one transaction.
- A unit that failed but is required by nobody (`Wants=`, not `Requires=`)
  must not drag the others down. A oneshot then answers s6-rc "success" and
  writes the failure to the log and the state. A required one answers
  honestly, and the units requiring it do not start.
- systemd breaks ordering cycles on the fly; `s6-rc-compile` does not accept
  them. `unitc` breaks them itself, starting with the weakest edge, and notes
  it in the report.
- A unit with `Requires=` on a unit that does not exist cannot be started
  (systemd would refuse too); it is excluded, with an entry in the report.

### Sockets

`.socket` is a oneshot that binds the sockets (`unit-socket`) and puts them
into `s6-fdholder` (the `unit-fdholder` service). The service takes them on
every start, so restarting the service does not close the socket. There is
no lazy first start: the socket's service is started right away. But a
stopped (or exited) service starts again when something arrives on the
socket, as with systemd: that is done by the `<socket>-activate` node
(`unit-runtime socket-activate`), which waits for the service to stop
(`s6-svwait`), then for input on the sockets (`unit-socket-wait`, `poll` on
copies from the fdholder, taking nothing from them), and calls `systemctl
start`. The kubo test stops ipfs and expects the next request to bring it
back up.

### Accept=yes

A socket with `Accept=yes` means "one process per connection"
(`sshd.socket`, `rsyncd.socket`): the template unit `foo@.service` is started
for every connection as `foo@COUNTER-LOCAL-REMOTE.service`.

- The sockets are still bound by the oneshot `foo.socket` and put into
  `s6-fdholder`. Next to it comes a longrun `foo.socket-accept`: it takes the
  sockets from there, `unit-accept` accepts connections and starts
  `unit-runtime accept-conn` for each.
- The template is compiled once, with a placeholder instance
  `ACCEPTINSTANCEPLACEHOLDER` (letters only, so it passes escaping
  unchanged); `accept-conn` substitutes the real name with `sed` and starts
  it like a normal service process with its own cgroup.
- The connection arrives as descriptor 3 (`LISTEN_FDS=1`) or, with
  `StandardInput=socket`, as stdin/stdout. `REMOTE_ADDR` and `REMOTE_PORT`
  are set as with systemd. `MaxConnections=` (64) limits the number of
  simultaneous ones.

### Timers

`.timer` is a long-running `unit-timer`: it parses `OnCalendar=` (including
lists, ranges, steps, weekdays, `~` for the end of the month, the time
zone), `OnBootSec=`, `OnUnitActiveSec=` and the rest, `Persistent=`,
`RandomizedDelaySec=`. When it fires it starts the service as a one-off job
(`unit-runtime job`) without touching the s6-rc state; while the job runs it
will not start a second one.

### Devices

A dependency on `dev-….device` becomes a oneshot that waits for the node to
appear (up to 90 s, as with systemd).

Units "wanted" by a device (`wantedBy = [ "sys-subsystem-net-devices-eth0.device" ]`;
this is how NixOS configures addresses) are handled in two ways:

- at boot such a device joins the transaction as a one-off check after
  `udevadm settle`: if it is there, its units start at their place in the
  ordering; if not, they do not start and hold nobody up;
- after boot the `device-watch` service listens to udev events and starts
  the units when the device appears. It also carries out the
  `SYSTEMD_WANTS` property from udev rules (`bluetooth.target`,
  `sound.target`).

## Switching the configuration

`$toplevel/bin/switch-to-configuration` (the same contract as in NixOS):

1. compares `switch.tsv` of the running and the new database;
2. stops the changed units (with the old definitions), except
   `stopIfChanged = false`;
3. runs the activation script;
4. `s6-rc-update` to the new database, marking the changed ones `restart`;
   it stops the services that disappeared by itself;
5. starts what is new by rank, reloads `reloadIfChanged`.

Since the live database holds only real requirements, a restart touches the
changed unit and what `Requires=` it, and nothing more.

At the end, as systemd does, `switch-to-configuration` "starts the active
targets": `systemctl start default.target`. For a target the shim starts
again everything it wants that is not running, whatever s6-rc thinks of it:
failed services (so switching to a still broken configuration fails the
second time too), oneshot jobs, what was stopped by hand.

Oneshot jobs (`Type=oneshot` without `RemainAfterExit=`) are "inactive" after
boot, and on `switch` systemd runs them again if the definition changed (this
is how `restartTriggers` of `nginx-config-reload` and rule reloads work).
Here it is the same: such units are collected into a `rerun` list and run
after everything else, in rank order.

## What systemd was not asked to do but did

As PID 1, systemd mounts the service file systems, brings up `lo`, sets the
host name and raises the open file limit by itself. NixOS modules do not do
this because they do not need to. Here it is `modules/system/early.nix` and
stage 2.

## Packages and systemd

systemd itself is not started in any mode. The question is a different one:
whether its libraries (`libsystemd`, `libudev`) and the whole package are in
the system's closure or not. `s6.systemdPackages` decides. Only the init
system and what is tied to it change; packages stay nixpkgs packages, and by
default they are the same binaries from the cache.

### `"replace"` (default)

Packages are taken from the cache as they are, and the libraries underneath
them are swapped (`system.replaceDependencies`, `modules/no-systemd.nix`):

| was | is |
|---|---|
| `libsystemd.so.0` (`systemdLibs`, `systemdMinimal`) | our own `libsystemd.so.0`: it needs `libelogind.so.0` and defines the same `LIBSYSTEMD_*` versions; what elogind lacks (about twenty sd-bus/sd-device/sd-event functions, varlink and JSON) are stubs returning `-ENOSYS` / `NULL`; the list is built at build time from `nm` of the original |
| `libudev.so.1` | `libudev` from eudev |
| the whole `systemd` package | the shim with the substituted libraries |
| `systemd-*-dev` (headers, `.pc`) | a dummy with a single `systemd.pc` |

The swap happens inside binaries by store paths, so a replacement has a name
of the same length (padded with underscores; the length is that of the store
path name, not the derivation's `name`: the `dev` output of `systemd-260.5`
is called `systemd-260.5-dev`). The hash is replaced in UTF-8 and also in
UTF-16, since Qt programs keep build-time paths as UTF-16 `QStringLiteral`s
(`pkgs/replace-direct-dependencies.nix`). elogind and eudev are taken from
the package set without systemd; otherwise the replacement would depend on
itself through PAM and D-Bus.

Two checks run when the system is built:

- **before the swap**: `nm`/`readelf` on every program of the closure
  confirm that all imported `sd_*` and `udev_*` symbols exist in the
  replacement libraries: such programs are linked with immediate binding
  and would not start otherwise;
- **after**: `system.forbiddenDependenciesRegexes` on the closure of the
  swapped system.

The checks work through import-from-derivation: evaluating the configuration
builds the system first. That is the price of the mode; in exchange nothing
is compiled.

Three more subtleties:

- On x86_64 the same is done for the 32-bit systemd (`pkgsi686Linux`): it is
  pulled in by 32-bit programs (pulseaudio with `support32Bit`, Steam, 32-bit
  graphics drivers). Replacements whose original is not in the closure are
  dropped up front, by the system's `closureInfo`, so the 32-bit parts are
  built only where needed and replaceDependencies does not warn about every
  unneeded one.
- A service with `confinement.enable` lives in a root made of the paths of
  its closure, listed before the swap: where systemd's libraries were, the
  list ends up naming their replacements, but not what the replacements are
  made of. So the replacements are added to `confinement.packages` of such
  services.
- `system.build.toplevelReplacedUnchecked` is the swapped system without the
  checks: if the "after" check fails, `nix why-depends` on it shows who still
  holds on to systemd (`toplevelUnreplaced` is the system before the swap).

### `"rebuild"`

`pkgs/no-systemd.nix`: most nixpkgs packages enable systemd support under
the condition `lib.meta.availableOn stdenv.hostPlatform systemd`; this is
how musl package sets are built. The overlay declares systemd unavailable,
and the support is turned off everywhere at once; `udev` becomes eudev. The
`pkgs.systemd` attribute itself points at the shim, so that modules taking
`systemctl` or `systemd-notify` from it get working commands.

The price: the NixOS binary cache has no such variants, so everything that
depends on D-Bus, udev, PAM or util-linux is built from source (about twenty
minutes for a server, hours for a desktop). This is the only mode that
changes the packages themselves; its test is `tests.rebuild` (not part of
the main suite).

### `"keep"`

Do nothing. systemd does not run, but its libraries, and in places the
package, stay in the closure.

In every mode except `keep`, `system.forbiddenDependenciesRegexes` will not
let a system with systemd in its closure build.

### The systemd-boot loader

A boot loader is not an init, and there is no reason to replace it:
`boot.loader.systemd-boot` works with the stock nixpkgs module, which only
needs `bootctl` (from `config.systemd.package`) and the EFI files next to
it. The shim takes these files from the real systemd package
(`pkgs/systemd-shim/boot-tool.nix`), but not the whole package:

- `bin/bootctl`, `lib/systemd/libsystemd-shared-*.so` (it does not start
  without it) and `lib/systemd/boot/efi` are copied;
- inside the copies the original package's path is replaced with the copy's;
  the copy's name has the same length (`boot-tool____`), as in the library
  swap, so `bootctl` finds its EFI files and library, and the closure has no
  reference to systemd;
- the library's RUNPATH is cut down to three packages: openssl and glibc (it
  is linked against them) and util-linux-minimal (where `bootctl` opens
  `libblkid` from). The other thirty (cryptsetup, FIDO2, TPM2, PAM) are for
  things a boot loader does not do, and some of them are built against
  `libsystemd`/`libudev` and would drag systemd into the closure. What is
  really opened can be seen with
  `strace -e openat bootctl … install | status | update`.

What ends up in the closure is about a dozen small paths: the package
itself, glibc, openssl, util-linux (`lib` and `login`), libidn2,
libunistring, libxcrypt, libgcc.

## Users of dynamic services

systemd hands out a `DynamicUser=` user for the lifetime of the service and
tells the whole system about it through nss-systemd, so `chown glance` in
`ExecStartPre=` and `getpwuid()` in the daemon work. Without nss-systemd the
runtime appends the user and group to `/etc/passwd` and `/etc/group` on the
first start (under a lock, the id from systemd's range by name, the next
free one if taken). Generating them at configuration build time through
`users.users` is not possible: listing `systemd.services` from `users.users`
loops back through `linger-users`, which reads `users.users`.

## Ways to plug it in

The module list is split in `modules/parts.nix`: those kept as they are
(`kept`), those kept only as option declarations (`optionsOnly`), those
replaced entirely (`dropped`) and our own (`ours`). Two ways of plugging in
come out of it, with the same result:

- `modules/module-list.nix`: `baseModules` for `lib/eval-config.nix`
  (`nixithos.lib.system`, `(import ./. { }).eval`);
- `modules/default.nix`: one module for the stock `nixpkgs.lib.nixosSystem`
  (`nixosModules.default`): `disabledModules` for `optionsOnly` and
  `dropped`, and the `optionsOnly` wrappers and `ours` in `imports`.

Comparing the same configuration built both ways (the `toplevel` of each):
the same files, the same closure; the hashes of `system-path` and of
everything referring to it differ, because of the order of the
`environment.systemPackages` list. The `module` and `module-units` tests are
`boot` and `units` with nodes built the second way (`moduleMode` in
`lib/testing.nix`).

## Starting during boot and restarting oneself

Two things systemd does with its job queue that have to be done explicitly
here.

**Starting while boot is in progress.** Boot is one `s6-rc` transaction, and
it holds the database lock. A unit that does `systemctl start X` during boot
(or a timer that fires early) cannot go through `s6-rc`; the shim starts the
service directly (`s6-svc -u`), and `s6-rc` does not know about it. The
final `s6-rc-update` would replace that service's directory and take it
away. So between the transaction and the switch to the second database
`rc.init` finds services that run but are not counted as up and says
`s6-rc -u change`: the process is already running, only the bookkeeping
changes. To keep anything from starting between that search and
`s6-rc-update`, `rc.init` holds `/run/units/.switch-lock` (exclusively), and
`systemctl` holds it shared during such a direct start, and only until "the
process is up" (it waits for readiness without the lock; and it will not
wait for the lock itself for more than ten seconds, so that a job inside
someone else's s6-rc transaction does not deadlock with `rc.init`). Without
this, `systemctl start --wait` at the very beginning of the borgbackup test
fell into that window: the job was killed by the switch and ended
"successfully" without having done anything.

**Between the end of the process and the result.** While `./finish` decides
how the run ended (s6: the service is "down and not ready"), `systemctl`
shows `deactivating`, not `inactive`: otherwise `start --wait` and
`wait_for_unit` took that moment for a successful finish.

**Restarting from inside.** `systemctl restart X` called by X's own process
(for example influxdb2's `ExecStartPost=`) cannot be carried out honestly: the
restart would kill the one doing it. The shim recognises such a call by the
cgroup (`/proc/self/cgroup`) and puts a `restart-requested` file into the
state directory. The runtime reads it in two places: after `ExecStartPost=`
(the start is done, the main process gets a signal) and in `finish` (a
restart without `RestartSec=` and with any `Restart=`). If the service is
already running, the shim signals the main process itself through
`s6-svc -t`.

**A timer's target is a service that stays.** A `job` for a non-oneshot
starts the service like `systemctl start` (through `s6-rc`, or `s6-svc -u`
if s6-rc considers it up but there is no process) instead of running
`ExecStart=` in the foreground.

## Journal and console

There is no single journal: every service has its own `s6-log` and a
directory in `/var/log/s6/`. `journalctl` gathers them and the
"Started/Stopped/Reached target" lines the runtime writes to
`/run/units/<unit>/journal`.

If `services.journald` asks for a console (`console = "/dev/ttyS0"` or
`ForwardToConsole=yes` + `TTYPath=` in `extraConfig`, which is what
`test-instrumentation` does for test machines), the system does the same:
the terminal's name goes into `/etc/units/console-log`, every service's
logger writes its lines there too (prefixed with the service's name), and
the runtime writes its own "Started X." prefixed with `systemd[1]:`. This is
what `wait_for_console_text` in tests relies on (more than thirty of them);
`wait_for_x` looks for "Reached target Current graphical", which is the
user manager's `graphical-session.target`.

The loggers themselves, the most frequent runtime call (every service, all
at once at boot), answer from the first lines of the script without parsing
the other seventeen hundred: bash executes a script as it reads it.

## Command privileges and the sandbox

A command prefixed with `+` in `ExecStartPre=` and the others runs "with
full privileges": neither `User=` nor the unit's namespaces
(`ProtectSystem=`, `PrivateTmp=`, `RootDirectory=`) apply to it, only to the
rest. `wpa_supplicant` uses this to create a file in `/etc` before the unit
starts reading it from a read-only root.

The working directory is entered again after the sandbox has mounted
everything it needs: otherwise it stays the directory under the
`ProtectSystem=strict` mount rather than the mount made writable
(`StateDirectory=`).

A private `/dev` gets `/dev/log`: `syslog(3)` has to go somewhere.

Without elogind, `systemd-inhibit` has nothing to lock, but while the
command runs a record of the lock lies in `/run/systemd/inhibit-shim`, and
`--list` shows it (the borgbackup test looks for its own there).

Binds (`BindPaths=`, `BindReadOnlyPaths=`) are mounted in path order, as
with systemd, not in the order written: `BindPaths=/etc/wpa_supplicant`
stays writable under `BindReadOnlyPaths=/etc/`. A bind into a private
`/tmp` (`PrivateTmp=` with `BindReadOnlyPaths=/tmp/bird`, the flap-alerted
test) goes on top of it, not under it; by that point the source path already
leads into the private directory, so the source is opened in advance and
mounted through `/proc/self/fd/N` (with `--no-canonicalize`: otherwise
`mount` turns the link back into a path).

`UMask=` is for what the command itself creates. The sandbox creates mount
points with 022: with `UMask=0077` and `RootDirectory=` (wpa_supplicant) the
root ended up impassable for the service's user.

`ProtectSystem=strict` follows systemd 260 in its non-obvious places too
(checked on stock NixOS with `systemd-run`): `/home`, `/root`, `/run/user`
stay writable, they are governed by `ProtectHome=`; `/run` is closed, but
open if the unit also has `ProtectProc=` or `ProcSubset=pid` (nginx does,
and the nginx-tmpdir test writes to `/run`).

`BindPaths=` stays writable under `ProtectSystem=strict` as well, which
makes everything else read-only (the same in systemd; wpa_supplicant saves
its configuration through such a bind). With `RootDirectory=`,
`MountAPIVFS=` is on by default, as in systemd: the root has `/proc`,
`/sys`, `/dev`, and with them `/dev/fd` (which `<(…)` in scripts relies
on).

`PrivateTmp=` lives where systemd puts it:
`/tmp/systemd-private-<boot id>-<unit>-XXXXXX/tmp`, and the same in
`/var/tmp` (tests look for it there). The directories are created on the
first command of a start, shared by all of its commands, and go away with
the service; tmpfiles rules (`x`/`X`, as in systemd's `tmp.conf`) keep
`/tmp` cleaning from touching them.

`RootDirectory=` is entered after `setpriv` (a root built from the closure,
as with confinement, does not contain `setpriv`), so `unit-chroot` gets
`CAP_SYS_CHROOT` for that moment: a user gets it as ambient, root gets it in
the bounding set together with `CAP_SETPCAP` if the unit's set lacks them;
after the chroot they are removed from there (`-B`). Otherwise a root
service with an empty `CapabilityBoundingSet=` (gonic) could not enter its
root.

`CPUSchedulingPriority=` is clamped to the policy's range, as in systemd:
`fifo`/`rr` without a priority get 1 (freeswitch).

`PAMName=`: the main process runs in a PAM session. `unit-pam` (C, as root)
opens the session (`pam_acct_mgmt`, `pam_setcred`, `pam_open_session`, with
`PAM_TTY` from `TTYPath=` if the unit has a terminal), adds the modules'
environment (`XDG_RUNTIME_DIR`, `XDG_SESSION_ID` from elogind) and starts
the command as a child process; it stays around to close the session and
forwards signals, like systemd's `(sd-pam)`. It sits in the chain before the
sandbox and the user switch. The `services.cage` kiosks and phosh rely on
it.

## Networking

`networking.useNetworkd` would hand the interfaces to systemd-networkd,
which is not here. The option is forced off: everything `networking.*`
describes (addresses, routes, VLANs, bridges) is set up by the scripted
implementation, as with the option off; nothing applies a hand-written
`systemd.network.*`, and there is a warning about it.

The exception is `.link` files (`systemd.network.links`): udev reads them,
not networkd, and through them NixOS sets an interface's MTU and MAC address
even with the scripted network (`networking.interfaces.<name>.mtu`,
`.macAddress`), and also Wake-on-LAN. The files are written to
`/etc/systemd/network`, as upstream does, and applied by `unit-link`
(`pkgs/unit-link`): eudev does not know them by itself. The
`75-unit-link.rules` rule picks the name (`Name=`) on `add` before eudev's
rules, and on `add` and `move` applies the rest: MTU, MAC, alias, queue
length, `WakeOnLan=`, autonegotiation, speed, duplex, offloads. As in
systemd-udevd, the first file by name whose `[Match]` fits wins
(`OriginalName`, `Name`, `MACAddress`, `PermanentMACAddress`, `Type`,
`Driver`, `Kind`, `Path`, `Property`, `Host`, `KernelCommandLine`); a
condition that cannot be checked makes the file not match, and a setting
that was not applied goes to syslog.

The `80-unit-link-keep.rules` rule keeps an interface's name when nobody
assigned one in this event (`NAME` = the current name), which is what
NamePolicy=keep does in systemd-udevd. Without it, rules like
`NAME=="enp1s0"` did not fire, and NixOS writes those itself
(`99-ipv6-privacy-extensions.rules`, temporary addresses per interface).

The host name from DHCP: dhcpcd (`networking.dhcpcd.setHostname`) runs as
its own user in its own UTS namespace and calls `hostnamectl set-hostname
--transient`; with systemd that is a D-Bus call to hostnamed, which polkit
allows for the dhcpcd user. Here `hostnamectl` talks to `hostname-agent`
(`modules/services/hostname.nix`): `s6-ipcserver` on
`/run/hostname-agent/socket`; the kernel says who is asking, and the
transient name can be changed by root and by users in
`s6.hostname.allowedUsers` (dhcpcd by default, if it sets the name). The
service exists only if the list is not empty.

Without a name in the configuration (`networking.hostName = ""`) stage 2
gives the machine a fallback, as systemd does: `DEFAULT_HOSTNAME` from
os-release, otherwise `localhost`. The dhcpcd hook renames only a machine
with such a "not yet named" name, and it does not count the kernel's
`(none)` as one. For the same reason the branding keeps
`DEFAULT_HOSTNAME=nixos`: with `nixithos` dhcpcd would not change the name
under systemd either.

## The D-Bus bus

The system bus is the reference dbus-daemon (`modules/services/dbus.nix`):
dbus-broker hands every activation request to systemd. It opens its socket
itself and reports readiness by writing its address to descriptor 3.

Without `--systemd-activation`, dbus-daemon starts a service by the `Exec=`
line of its `.service` file (through a setuid helper, as `User=`). For
services that systemd would start through a unit (`SystemdService=`), this
is not enough: `Exec=` there is often a stub (`/bin/false`) or a bare
command line without the unit's settings (`wpa_supplicant -u` does not know
the interfaces from `networking.wireless.interfaces`). So a directory of
copies of such files is built from all `services.dbus.packages`, and
dbus-daemon looks there first (for the same name the first directory wins):
their `Exec=` is `dbus-unit-activate UNIT NAME` as root, which does
`systemctl start UNIT` and stays until the name appears on the bus (an
activation whose process ended earlier is a failure for dbus-daemon) or the
unit fails. Users' session buses do not do this: there the services' `Exec=`
lines are real.

## Time

`services.timesyncd` (on by default) is implemented by `unit-sntp`: a small
SNTP client (`modules/services/timesyncd.nix`). It reads the same
`/etc/systemd/timesyncd.conf` (`NTP=`, `FallbackNTP=`, `PollInterval*Sec=`),
runs as the `systemd-timesync` user with one capability (`CAP_SYS_TIME`),
keeps the clock from falling behind the file
`/var/lib/systemd/timesync/clock`, and on a server's answer either sets the
time (an offset of more than 0.4 s) or slews it with `adjtime`, and creates
`/run/systemd/timesync/synchronized`. `timedatectl` is a shim: `status`,
`show`, `set-timezone`, `list-timezones`, `timesync-status`.

## Sessions: elogind

`services.elogind.enable` (turns itself on with `services.xserver`,
`services.displayManager`, `services.greetd`, `services.cage`, sway,
hyprland, niri, labwc, wayfire) is the standalone logind: sessions, seats,
`loginctl`, `/run/user/UID`, the `org.freedesktop.login1` D-Bus service that
polkit, `libseat` and desktops talk to. The options are the stock ones,
`services.logind.settings`.

- The service is called `systemd-logind.service` (that is how other units
  wait for it), `elogind` in s6; the PAM module `pam_elogind.so` sits in the
  shim under the name `pam_systemd.so`, so the PAM rules from nixpkgs pick it
  up by themselves.
- cgroup v2 in unified mode: elogind gets no "group became empty"
  notification (there is no release agent), so it watches the session
  leader. A zombie leader not yet reaped by its parent counted as "alive",
  and the session hung in `closing`. `logind-session.c` is patched in
  elogind: for a session that is already stopping the leader is not
  checked.
- When the last session closes, elogind removes `/run/user/UID`. The user
  service manager (below) must be stopped by that moment, so while it runs
  `user-manager` turns on a *temporary* linger for the user and turns it off
  afterwards (`loginctl enable-linger`).

## User services

`systemd.user.services|sockets|timers|targets` and `systemctl --user`. The
order of things is the same as for system services: `unitc --scope user`
compiles the directory of user units into a **separate database**
`<s6-db>/user` (`compiled-boot` and `compiled`). Then, for every user:

```
PAM (pam_exec: user-manager hook)       — open_session / close_session
        │ keeps track of sessions in /run/user-managers/.sessions/UID/
        ▼
/run/user-managers                      — the scan directory run by the
        │                                 `user-managers` system service
        ▼
s6-supervise user-UID → user-manager run → setpriv + a clean environment
        ▼
user-manager session  (as the user)
        ├─ s6-svscan /run/user/UID/service
        ├─ s6-rc-init, s6-rc -u change default, s6-rc-update (as rc.init)
        └─ on TERM: s6-rc -bDa change, s6-svscanctl -t
```

- root and ordinary users (UID ≥ 1000) have a manager, like
  `user@UID.service`; for system accounts systemd creates "light" sessions
  without a manager.
- The manager comes up with the user's first session, survives a quick
  re-login (5 s) and stops after the last one. It is not stopped by the hook
  (everything the hook leaves in the background is a process in the
  session's cgroup, and the session would not close), but by the
  `user-managers` service.
- Stopping: the directory first *leaves the scan directory* (renamed to
  `.gone-UID`), then `s6-svc -d`, waiting, `s6-svc -x`. Otherwise
  s6-svscan starts `s6-supervise` again for a directory without a
  supervisor, and the new supervisor starts the service (there is no `down`
  file): the manager "came back to life" without a directory through which
  anything could be said to it.
- The databases live in the store, and s6-rc copies service directories out
  of them where supervisors need to write: so the manager copies the
  database to `/run/user-managers/.state/UID/db` and opens it for writing.
- The manager keeps its own files (the scan directory, s6-rc, the database
  copy, unit state) in `/run/user-managers/.state/UID`, not in
  `$XDG_RUNTIME_DIR`: the login manager removes `/run/user/UID` as soon as
  the user has no sessions and no linger, while the manager has to stay
  reachable until its services are stopped. `systemctl --user` finds it
  there too (`UNIT_USER_STATE`); `--machine=USER@` runs the same program
  again as the user.
- Users with linger (`loginctl enable-linger`,
  `users.users.<name>.linger`) get a manager without a session, from boot;
  `disable-linger` stops it a few seconds later. The linger files are
  `/var/lib/elogind/linger` or `/var/lib/systemd/linger`; without elogind,
  `loginctl` is a small shim that only handles them.
- Environment: `/etc/set-environment`, `UNIT_SCOPE=user`,
  `XDG_RUNTIME_DIR`, `UNIT_USER_STATE`. `systemctl --user
  import-environment` / `show-environment` work.
- The session bus is an ordinary user service `dbus`
  (`dbus-daemon --session --address=unix:path=%t/bus --print-address=3`).
- The user's sockets live in their own `s6-fdholder` (`unit-fdholder`).
- Without elogind the service still works: the hook creates `/run/user/UID`
  itself and removes it on stop.

## Testing

`tests/`: tests on NixOS's stock driver (QEMU, `machine.succeed(…)`).
`lib/testing.nix` swaps the node's base module list in it.

- `boot`: booting, early services, logs, service control, shutdown;
- `units`: one unit property per service: environment, user, hooks,
  `Restart=`, readiness, ordering, sockets, timers, capabilities…;
- `switch`: switching there and back, checking that unrelated services are
  not restarted;
- `login`: console login and ssh between two machines;
- `replace`: the `"replace"` mode: no systemd in the closure, programs work
  on the swapped libraries;
- `elogind`: sessions, `loginctl`, `/run/user/UID`, closing a session;
- `user-services`: the user manager: starting with the first login,
  services, `systemctl --user`, sockets, the bus, the environment, stopping,
  coming back;
- `sandbox`: every sandbox directive with one unit each, checking the
  verdict from inside and outside;
- `timesync`: the clock follows the server (our own SNTP server in Python in
  the VM);
- `bootloader`: an installed system: GRUB (BIOS), Limine and systemd-boot
  (UEFI) boot into s6, `switch-to-configuration boot` reinstalls the boot
  loader, reboot;
- `module`, `module-units`: `boot` and `units` with nodes from the stock
  nixpkgs module list and `nixosModules.default`;
- `rebuild`: `boot` in `"rebuild"` mode; not part of the main suite (hours
  of building).

### nixpkgs tests

`nix-build -A upstream.<name>` runs a stock NixOS test against this tree, on
binaries from the cache (`replace`). The list and the names are the same as
in `nixosTests`: `nixos/tests/all-tests.nix` itself is used, with every
argument it gives the tests (`getPackage` for cassandra, `networkd = false`
for `networking.scripted.*`, groups such as `postgresql.*`). All tests there
are built through `nixos/lib/testing-python.nix`; `upstreamTree` in
`default.nix` is a copy of `nixos/tests` next to links to the rest of the
nixpkgs tree, in which that file is replaced with an adapter to the harness
from `lib/testing.nix` (which swaps the node's module list). So both
`runTest` from all-tests.nix and the old tests (`make-test-python.nix`)
build machines from this tree. The few entries that go around the harness
(package tests, checks of the evaluated configuration) would test stock
NixOS; they are rejected when accessed (our own carry the
`passthru.nixithos` mark).

`node.pkgs` (upstream gives tests one read-only package set for all
machines) is here the machines' package set with the tree's overlay, and not
read-only: the machines get their packages through their own `nixpkgs.*`.
