# Status

**English** · [Русский](ru/status.md)

Checked by tests in QEMU (`nix-build -A tests.<name>`), nixpkgs `nixos-26.05`.
The suite is twelve tests (ten of our own and two runs of the same `boot` and
`units` through `nixosModules.default`), and all of them pass. `tests.rebuild`
(`boot` in `rebuild` mode, hours of building) is not part of the suite.

## Works

| what | checked by |
|---|---|
| booting to `multi-user.target`, clean shutdown | `boot` |
| initrd with eudev, udev in the system, coldplug | `boot` |
| tmpfiles, setuid wrappers, users, PAM, console login | `boot`, `login` |
| D-Bus (system bus), nscd, dhcpcd, static addresses, firewall | `boot`, `login` |
| sshd | `login` |
| nix-daemon with its socket | `boot` |
| syslog (`/dev/log`), kernel log, service logs, `journalctl -u` | `boot` |
| `systemctl start/stop/restart/reload/status/is-active/…` | `boot`, `units` |
| service types `simple`, `oneshot`, `forking`, `notify`, `notify-reload` | `units` |
| `Environment*`, `User/Group`, `*Directory`, `UMask`, `Limit*`, capabilities, `NoNewPrivileges`, `LoadCredential`, `WorkingDirectory`, `StandardOutput=file:` | `units` |
| `ExecStartPre/Post`, `ExecReload`, `ExecStop/StopPost` | `units` |
| `Restart=`, `StartLimit*`, `Condition*` | `units` |
| ordering, soft and hard failures | `units` |
| `.socket` (except `Accept=yes`), `.timer`, templates `foo@bar` | `units` |
| stopping a service together with its children (cgroup) | `units` |
| `switch-to-configuration` (`switch`, `test`, `boot`, `dry-activate`), re-running changed oneshot jobs | `switch` |
| a closure without systemd and its libraries, on packages from the cache: `libsystemd` → `libelogind`, `libudev` → eudev (`replace`, the default) | `replace`, the build: `forbiddenDependenciesRegexes` |
| the same with packages rebuilt without systemd support (`rebuild`) | `tests.rebuild` |
| one module for the stock `nixpkgs.lib.nixosSystem` (`nixosModules.default`) | `module`, `module-units` |
| elogind: sessions, `loginctl`, `/run/user/UID`, closing the last session | `elogind` |
| user services: a manager per user, `systemctl --user`, sockets, the session bus, the environment, stopping and coming back | `user-services` |
| boot loaders GRUB (BIOS), Limine and systemd-boot (UEFI): installing, booting into s6, reinstalling, rebooting | `bootloader` |
| sandbox: `PrivateTmp/Devices/Network`, `ProtectSystem`, `ProtectHome`, `Read*Paths`, `InaccessiblePaths`, `BindPaths`, `TemporaryFileSystem`, `ProtectKernel*`, `DynamicUser` | `sandbox` |
| `Accept=yes` sockets (`sshd.socket`, `rsyncd.socket`) | `units`, `upstream.rsyncd` |
| `.path` units (once a second), `OnFailure=`, `OnSuccess=`; "Started/Stopped/Reloaded" lines in `journalctl -u` | `units`, `upstream.nginx` |
| network time (`services.timesyncd`), `timedatectl` | `timesync` |
| console keymap (`console.keyMap`) | `boot` |
| `RootDirectory=` (tor), `MountAPIVFS=`, `RootDirectoryStartOnly=` | `sandbox`, `upstream.transmission` |
| the user manager for linger without a session, `systemctl --user --machine=USER@` | `user-services` |
| `systemd-analyze security`: systemd's real analyzer in `--offline` mode (a copy without systemd in the closure, `client-tools.nix`), with its weights and `--threshold=`; `busctl`; `journalctl -o cat`, `timedatectl` | `upstream.radicale`, `upstream.pdudaemon`, `upstream.dovecot`, `upstream.systemd-escaping` |
| `DynamicUser=`: the user and group are in `/etc/passwd`, `/etc/group` from the first start | `sandbox`, `upstream.dex-oidc`, `upstream.glance` |
| a service asks for its own restart (`systemctl restart` from its `ExecStartPost=` or its process) | `units` (`t-self-start`, `t-self-run`), `upstream.influxdb2` |
| the target of a timer or path unit that is not a oneshot: the daemon starts as with `systemctl start` | `units` (`t-job-simple`, `t-job-daemon`), `upstream.keepalived` |
| a service started by hand during boot survives the switch to the second database | `upstream.keepalived` |
| the NixithOS name in `/etc/os-release` (`ID_LIKE=nixos`), the logo in fastfetch | `boot` |
| the specifiers `%d` (credentials directory) and `%o` (ID from os-release) | `upstream.c2fmzq` |
| `systemctl start --wait`, `show` properties (`ExecMainStatus`, `NRestarts`, unit file keys) | `units`, `upstream.borgbackup` |
| `rsyslogd` as the system syslog (`syslog.socket`, `/dev/log` on its socket) | `upstream.rsyslogd` |
| service logs and "Started …" on the console when journald is asked to (`wait_for_console_text`) | `upstream.mosquitto` |
| a `+` command without the unit's sandbox; a working directory under `ProtectSystem=strict`; `/dev/log` in a private `/dev` | `sandbox` |
| `systemctl --no-block` for every operation; `LastTriggerUSec*` on timers | `upstream.keepalived` |
| `Reached target …` in the journal for targets, user ones included | `upstream.chipass` (`wait_for_x`) |
| `.link` files (`systemd.network.links`): MTU, MAC, name, WoL, applied for eudev by `unit-link`; a name nobody assigned stays `NAME` for udev rules | `boot`, `upstream.networking.scripted.*` |
| `PAMName=`: the main process in a PAM session (the `services.cage` kiosk, phosh) | `elogind`, `upstream.dwl` |
| the host name from DHCP (`networking.dhcpcd.setHostname`): `hostnamectl --transient` as a user through `hostname-agent` | `boot`, `upstream.networking.scripted.dhcpHostname` |
| the user service manager for root (`systemctl --user` as root) | `upstream.emacs-daemon` |
| `BindPaths` into a private `/tmp`, binds ordered by path, `BindPaths` writable under `ProtectSystem=strict`, `UMask=` leaves mount points alone, `MountAPIVFS=` on by default with `RootDirectory=` | `sandbox`, `upstream.flap-alerted`, `upstream.wpa_supplicant.*` |
| quotes in the middle of a word in `ExecStart=`, `Environment=` | `upstream.cfssl` |
| `CPUSchedulingPolicy=fifo` without a priority | `upstream.freeswitch` |
| `notify-reload`: the notification socket for the whole run | `login`, `upstream.openssh` |
| `deactivating` between the end of the process and the result; `start --wait` during boot | `units`, `module-units`, `upstream.borgbackup` |
| activating system D-Bus services through a unit (`SystemdService=`): `systemctl start` until the name shows up on the bus | `upstream.wpa_supplicant.basic` |
| `systemd-inhibit` without elogind: the lock is recorded while the command runs, `--list` shows it | `upstream.borgbackup` |
| a machine with no name in the configuration gets the fallback one (`DEFAULT_HOSTNAME`), as with systemd | `upstream.networking.scripted.dhcpHostname` |
| `replace` mode and 32-bit programs (`pkgsi686Linux`) | `upstream.pulseaudio.*` |
| `PrivateTmp=` in `/tmp/systemd-private-…`, which `/tmp` cleaning leaves alone | `upstream.nginx-tmpdir` |
| a root service with an empty `CapabilityBoundingSet=` and `RootDirectory=` | `sandbox`, `upstream.gonic` |
| tmpfiles rules in files named as systemd's (`tmp.conf`, `var.conf`…): `systemd.tmpfiles.rules` override them; `%b`/`%m` without a newline (`/tmp` cleaning leaves running services' `PrivateTmp=` alone) | `upstream.nginx-tmpdir` |
| `ProtectSystem=strict` with `ProtectProc=`/`ProcSubset=` leaves `/run` writable, as in systemd 260 | `upstream.nginx-tmpdir` |
| a `.mount` with `bind` creates the source directory | `upstream.prowlarr` |
| `switch-to-configuration` starts `sysinit-reactivation.target` (`systemd-tmpfiles-resetup`: home directories of new users) | `upstream.userborn` |
| `Type=idle` waits for the end of boot (up to 5 s); s6-rc lines are not printed on a console while getty owns its terminal; getty restarts ~110 ms after logout | `upstream.shadow`, `upstream.sssd-ldap` |
| getty on tty2+ starts on switching to that console (like logind's autovt), `X-WaitForVT=` | `upstream.rtkit` |
| D-Bus activation through a unit on the session bus; `Type=dbus` for user services; `DBUS_SESSION_BUS_ADDRESS` in the user manager and in the session (`pam_s6_env`) | `upstream.pass-secret-service`, `upstream.lomiri-gallery-app.*` |
| the user manager in the `systemd-user` PAM session (`makeHomeDir`); login waits for it to start, like pam_systemd | `upstream.sssd-ldap`, `user-services` |
| slurm without systemd (`IgnoreSystemd=yes` in cgroup.conf) | `upstream.slurm` |
| AppArmor profiles (`apparmorRulesFromClosure`) in `replace` mode: the replacement libraries are allowed in `abstractions/base` | `upstream.mumble` |
| a service behind a socket (not `Accept=yes`) starts on first use, not at boot, as with systemd | `boot`, `upstream.lxd-image-server`, `upstream.kubo` |
| `systemd-run`: `-p StandardOutput=/StandardError=/WorkingDirectory=/Environment=/User=/Group=`, `--working-directory DIR`, `--user --machine=USER@` | `upstream.benchexec` (up to its D-Bus API call) |
| `RootDirectory=`: the directory becomes the root of the service's namespace (`nsenter -m` sees what the service sees); `+` commands run inside it with the binds and `ReadWritePaths=` but without the other restrictions, as in systemd 260 | `upstream.aesmd`, `sandbox` |
| user units from profile packages (`$XDG_DATA_DIRS/systemd/user`); `PartOf=` on user units | `upstream.ayatana-indicators` |
| `systemctl show -p Environment`, `systemctl --user --machine=USER@ is-enabled` without a running manager | `upstream.aesmd`, `upstream.atuin-programs` |
| the `systemd-journal` group (named in `SupplementaryGroups=`); `systemd-run -p EnvironmentFile=` | `upstream.alloy`, `upstream.atticd` |
| `Requires=`/`BindsTo=` cycles without `After=` are broken at the unordered edge (cockpit's sockets `BindsTo=cockpit.service`); a system without Nix (`nix.enable = false`) builds in `replace` mode too | `upstream.without-nix` |
| ISO (`nix-build -A iso`): BIOS and UEFI boot with the NixithOS mark, a live system, `nixos-generate-config` + `nixos-install` on GPT with systemd-boot, booting the installed system | by hand in QEMU (16.10) |
| ISO with dwl (`nix-build -A isoDwl`): Calamares with its own branding, "Erase disk" on GPT/UEFI, the installed system logs into dwl; kpmcore looks for programs in `/run/current-system/sw` too (pkgs/overlay.nix) | by hand in QEMU (16.10) |
| graphical ISO (`nix-build -A isoGraphical`): LXQt on labwc, Calamares starts by itself, the panel with its plugins (path hashes in UTF-16 are rewritten by the replacement, `pkgs/replace-direct-dependencies.nix`) | by hand in QEMU (17.10) |
| the console installer (`nix-build -A iso`, `pkgs/nixith-installer`): every step in English and Russian, Wi-Fi/cable through `nmcli`, erase-disk install on GPT/UEFI with Parallax and ly, the installed system boots and takes the password; `console.font` set again when the graphics driver takes the console over (a udev rule on `vtcon*`, as systemd's 90-vconsole.rules) | by hand in QEMU (18.10) |
| `journalctl -g` on the message text (case-insensitive unless there are capitals), exit code 1 when nothing matches; `-t` by name | `upstream.mumble` |

## Known not to work

| what | why |
|---|---|
| `networking.useNetworkd`, `systemd.network.*` | there is no systemd-networkd; the option is forced off and the scripted network is used |
| `services.resolved`, `boot.initrd.systemd` (and everything on top of it: systemd-repart in the initrd, swap-random-encryption), `systemd.sysusers` (as an implementation) | no replacements of our own; the options are there, their enablement is forced to `false` |
| tests that check systemd itself (`systemd-networkd*`, `systemd-nspawn`, `systemd-machinectl`…) | that is not init |
| tests with `curl` ≥ 8.22 and a cookie file for a host without a dot (engelsystem) | curl drops such cookies without this tree as well |
| ferm (legacy `ip6tables`) | the 6.18 kernel from nixpkgs has no `ip6_tables`, neither as a module nor built in; the same without this tree |
| tests with `requiredSystemFeatures = [ "uid-range" ]` (evcc and similar) | needs `auto-allocate-uids` in the host's Nix |
| `services.journald.upload` (systemd-journal-upload; victorialogs) | a journald feature |
| tests of `systemd.network.*` (rkvm) | there is no systemd-networkd |
| `system.etc.overlay` (userborn-static) | requires `boot.initrd.systemd` |
| `containers.*` containers (rstp, ndppd) | nspawn |
| programs that talk to systemd itself over D-Bus (`org.freedesktop.systemd1`: transient units, scopes with cgroup delegation; benchexec through pystemd) | the systemd manager's API; on a GNOME session bus part of it is there: `GetUnit`, `Start/Stop/RestartUnit`, `ResetFailed`, the environment ([systemd1-bus](../pkgs/systemd-shim/systemd1-bus.py)), which is enough for gnome-session 50 |
| tests of systemd features: pstore, coredump, sysusers, repart | that is not init |

## Not done

| what | state |
|---|---|
| seccomp directives (`SystemCallFilter=`, `RestrictAddressFamilies=`, `MemoryDenyWriteExecute=`, `RestrictNamespaces=`…), `PrivateUsers=`, `ProtectProc=`, `RootImage=` | not applied; which unit has them is in the database's `report.txt` |
| `.automount` | the unit is skipped, with an entry in the report |
| a template instance that is not in the configuration (`systemctl start foo@new`) | does not start; cockpit depends on this (`cockpit-wsinstance-https@HASH.socket`). The ones named in dependencies and the ones with their own drop-in directory (`gnome-session@gnome.target.d`) are built |
| connman's access point (`connmanctl tether wifi`) | connman's DNS proxy cannot take port 53 on the tether interface; not investigated |
| an emergency shell when boot fails | none |
| `nixos-rebuild` as a command | not checked |
| containers (`boot.isContainer`, nspawn) | not checked |

## Behaviour differences

- `DynamicUser=`: the user does not disappear after the service stops (the
  entry in `/etc/passwd` stays; with `users.mutableUsers = false` the next
  activation removes it and the service adds it again on start), and the
  numeric id comes from systemd's range (61184–65519), picked by name rather
  than free at the moment of start.
- `EnvironmentFile=` with a relative path is dropped with a warning, as in
  systemd.
- `Type=exec`: readiness comes right after the main process is started;
  there is no check that the executable actually got loaded. That is why
  `axlisten`'s "after kissattach" ordering sometimes loses the race.
- `After=` on a long-running service that failed to start: dependents wait
  for the end of boot and start in a second pass, not right away.
- After the supervisor restarts a service, `ExecStartPost=` runs again, as in
  systemd; `foo-hooks` (where `ExecStop=` lives) stays "up", though.
- `systemctl stop` does not change the state in s6-rc: the service is
  stopped, but `s6-rc -a list` still shows it (`s6-rc diff` sees this).
- Logs are text files; there are no structured journal fields.
- With elogind the user service manager lives in the cgroup of the user's
  session (elogind's hierarchy is flat, and it knows who owns a process only
  through the session); without a session it is in
  `user.slice/user-UID.slice/user@UID.service`, as with systemd. While it is
  there, the session may stay `closing` after logout (with linger).
- User service logs are in `~/.local/state/s6`; for a user without a home
  directory, in the state directory of their manager.
- Under load (several VMs on one machine) kubo and emacs-daemon sometimes do
  not fit into the test timeouts; one at a time they pass.
- Boot is slower than systemd where dozens of units start at once on one
  processor: each goes through the bash runtime. In a VM with one vCPU the
  interface addresses appear about a second later than services without
  network dependencies; tests that reach for another machine right after
  boot without waiting for the network (vsftpd, mosquitto) sometimes lose
  that race.
- `.link`: a `[Match]` with `Virtualization=`, `Architecture=`,
  `Credential=` and the like does not select the file (nothing to check them
  with); from `[Link]` the policies are not applied (`NamePolicy=`,
  `MACAddressPolicy=`; eudev gives the names) nor rare keys such as the
  network card's channels and rings, which is noted with a line in syslog.
- A session that still has someone else's processes may stay `closing` on
  cgroup v2: elogind has no "group became empty" notification.
- `replace` mode: programs contain code that talks to systemd (`sd_notify`,
  `sd_login_*`, …), and it works on elogind; what elogind does not have
  (`sd_bus_*` to systemd's services and the like) the build will not let
  through.

## nixpkgs tests (`upstream.*`)

`nix-build -A upstream.<name>` (1105 tests are available, `replace` mode).
Passing: haproxy, memcached, unbound, nats, doas, atd, rsync, rsyncd,
tinyproxy, chrony, sudo, openssh (with `startWhenNeeded`), nginx, bind,
knot, dovecot, postfix, redis, samba, stunnel, lighttpd, etcd, nsd,
zookeeper. Failing for reasons outside this tree: `locale` and `console` (in
this nixpkgs revision `vconsoleConf` is interpolated as a function),
`consul`, `vault-dev` (unfree), `telegraf` (needs `auto-allocate-uids` in
Nix), `keymap` (X11). Failing because the test checks systemd itself: `kea`
(`systemd-networkd-wait-online`), `fail2ban` (reads journald),
`systemd-confinement` (`confinement.enable` builds a root from the closure,
and our `setpriv` is not inside it).
