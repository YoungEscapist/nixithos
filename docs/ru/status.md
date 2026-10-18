# Состояние

[English](../status.md) · **Русский**

Проверено тестами в QEMU (`nix-build -A tests.<имя>`), nixpkgs `nixos-26.05`.
Набор — двенадцать тестов (десять своих и два прогона тех же `boot` и `units`
через `nixosModules.default`), все проходят. `tests.rebuild` (`boot` в режиме
`rebuild`, часы сборки) в набор не входит.

## Работает

| что | чем проверено |
|---|---|
| загрузка до `multi-user.target`, чистое выключение | `boot` |
| initrd с eudev, udev в системе, coldplug | `boot` |
| tmpfiles, setuid-обёртки, пользователи, PAM, вход с консоли | `boot`, `login` |
| D-Bus (системная шина), nscd, dhcpcd, статические адреса, firewall | `boot`, `login` |
| sshd | `login` |
| nix-daemon с сокетом | `boot` |
| syslog (`/dev/log`), лог ядра, логи сервисов, `journalctl -u` | `boot` |
| `systemctl start/stop/restart/reload/status/is-active/…` | `boot`, `units` |
| типы сервисов `simple`, `oneshot`, `forking`, `notify`, `notify-reload` | `units` |
| `Environment*`, `User/Group`, `*Directory`, `UMask`, `Limit*`, capabilities, `NoNewPrivileges`, `LoadCredential`, `WorkingDirectory`, `StandardOutput=file:` | `units` |
| `ExecStartPre/Post`, `ExecReload`, `ExecStop/StopPost` | `units` |
| `Restart=`, `StartLimit*`, `Condition*` | `units` |
| порядок, мягкие и жёсткие отказы | `units` |
| `.socket` (кроме `Accept=yes`), `.timer`, шаблоны `foo@bar` | `units` |
| остановка сервиса вместе с потомками (cgroup) | `units` |
| `switch-to-configuration` (`switch`, `test`, `boot`, `dry-activate`), повторный запуск изменившихся разовых заданий | `switch` |
| замыкание без systemd и его библиотек на пакетах из кэша: `libsystemd` → `libelogind`, `libudev` → eudev (`replace`, по умолчанию) | `replace`, сборка: `forbiddenDependenciesRegexes` |
| то же с пересборкой пакетов без поддержки systemd (`rebuild`) | `tests.rebuild` |
| один модуль для штатного `nixpkgs.lib.nixosSystem` (`nixosModules.default`) | `module`, `module-units` |
| elogind: сессии, `loginctl`, `/run/user/UID`, закрытие последней сессии | `elogind` |
| пользовательские сервисы: менеджер на пользователя, `systemctl --user`, сокеты, сессионная шина, окружение, остановка и возврат | `user-services` |
| загрузчики GRUB (BIOS), Limine и systemd-boot (UEFI): установка, загрузка в s6, переустановка, перезагрузка | `bootloader` |
| песочница: `PrivateTmp/Devices/Network`, `ProtectSystem`, `ProtectHome`, `Read*Paths`, `InaccessiblePaths`, `BindPaths`, `TemporaryFileSystem`, `ProtectKernel*`, `DynamicUser` | `sandbox` |
| `Accept=yes` сокеты (`sshd.socket`, `rsyncd.socket`) | `units`, `upstream.rsyncd` |
| `.path`-юниты (раз в секунду), `OnFailure=`, `OnSuccess=`; строки «Started/Stopped/Reloaded» в `journalctl -u` | `units`, `upstream.nginx` |
| сетевое время (`services.timesyncd`), `timedatectl` | `timesync` |
| раскладка консоли (`console.keyMap`) | `boot` |
| `RootDirectory=` (tor), `MountAPIVFS=`, `RootDirectoryStartOnly=` | `sandbox`, `upstream.transmission` |
| менеджер пользователя для linger без сессии, `systemctl --user --machine=USER@` | `user-services` |
| `systemd-analyze security` — настоящий анализатор systemd в режиме `--offline` (копия без systemd в замыкании, `client-tools.nix`), с его весами и `--threshold=`; `busctl`; `journalctl -o cat`, `timedatectl` | `upstream.radicale`, `upstream.pdudaemon`, `upstream.dovecot`, `upstream.systemd-escaping` |
| `DynamicUser=`: пользователь и группа есть в `/etc/passwd`, `/etc/group` с первого старта | `sandbox`, `upstream.dex-oidc`, `upstream.glance` |
| сервис просит перезапуск сам (`systemctl restart` из своего `ExecStartPost=` или процесса) | `units` (`t-self-start`, `t-self-run`), `upstream.influxdb2` |
| цель таймера или path-юнита, не oneshot: демон запускается как `systemctl start` | `units` (`t-job-simple`, `t-job-daemon`), `upstream.keepalived` |
| сервис, запущенный вручную во время загрузки, переживает переход на вторую базу | `upstream.keepalived` |
| имя NixithOS в `/etc/os-release` (`ID_LIKE=nixos`), логотип в fastfetch | `boot` |
| спецификаторы `%d` (каталог учётных данных) и `%o` (ID из os-release) | `upstream.c2fmzq` |
| `systemctl start --wait`, свойства `show` (`ExecMainStatus`, `NRestarts`, ключи файла юнита) | `units`, `upstream.borgbackup` |
| `rsyslogd` как системный syslog (`syslog.socket`, `/dev/log` на его сокет) | `upstream.rsyslogd` |
| логи сервисов и «Started …» на консоль, если journald просит (`wait_for_console_text`) | `upstream.mosquitto` |
| команда с `+` без песочницы юнита; рабочий каталог под `ProtectSystem=strict`; `/dev/log` в приватном `/dev` | `sandbox` |
| `systemctl --no-block` для всех операций; `LastTriggerUSec*` у таймеров | `upstream.keepalived` |
| `Reached target …` в журнале для целей, в том числе пользовательских | `upstream.chipass` (`wait_for_x`) |
| `.link`-файлы (`systemd.network.links`): MTU, MAC, имя, WoL — для eudev их применяет `unit-link`; имя, которого никто не назначил, остаётся `NAME` для правил udev | `boot`, `upstream.networking.scripted.*` |
| `PAMName=`: главный процесс в PAM-сессии (киоск `services.cage`, phosh) | `elogind`, `upstream.dwl` |
| имя хоста от DHCP (`networking.dhcpcd.setHostname`): `hostnamectl --transient` от имени пользователя через `hostname-agent` | `boot`, `upstream.networking.scripted.dhcpHostname` |
| менеджер пользовательских сервисов у root (`systemctl --user` под root) | `upstream.emacs-daemon` |
| `BindPaths` внутрь приватного `/tmp`, порядок привязок по путям, `BindPaths` записываемы под `ProtectSystem=strict`, `UMask=` не трогает точки монтирования, `MountAPIVFS=` по умолчанию с `RootDirectory=` | `sandbox`, `upstream.flap-alerted`, `upstream.wpa_supplicant.*` |
| кавычки посреди слова в `ExecStart=`, `Environment=` | `upstream.cfssl` |
| `CPUSchedulingPolicy=fifo` без приоритета | `upstream.freeswitch` |
| `notify-reload`: сокет уведомлений на всё время работы | `login`, `upstream.openssh` |
| `deactivating` между концом процесса и итогом; `start --wait` во время загрузки | `units`, `module-units`, `upstream.borgbackup` |
| активация системных служб D-Bus через юнит (`SystemdService=`): `systemctl start`, пока имя не появится на шине | `upstream.wpa_supplicant.basic` |
| `systemd-inhibit` без elogind: блокировка записана, пока команда работает, `--list` её показывает | `upstream.borgbackup` |
| машина без имени в конфигурации получает запасное (`DEFAULT_HOSTNAME`), как при systemd | `upstream.networking.scripted.dhcpHostname` |
| режим `replace` и 32-битные программы (`pkgsi686Linux`) | `upstream.pulseaudio.*` |
| `PrivateTmp=` в `/tmp/systemd-private-…`, очистка `/tmp` его не трогает | `upstream.nginx-tmpdir` |
| root-сервис с пустым `CapabilityBoundingSet=` и `RootDirectory=` | `sandbox`, `upstream.gonic` |
| правила tmpfiles в файлах с теми же именами, что у systemd (`tmp.conf`, `var.conf`…): `systemd.tmpfiles.rules` перекрывают их; `%b`/`%m` без перевода строки (очистка `/tmp` не трогает `PrivateTmp=` работающих сервисов) | `upstream.nginx-tmpdir` |
| `ProtectSystem=strict` с `ProtectProc=`/`ProcSubset=` оставляет `/run` записываемым, как в systemd 260 | `upstream.nginx-tmpdir` |
| `.mount` с `bind` создаёт каталог-источник | `upstream.prowlarr` |
| `switch-to-configuration` запускает `sysinit-reactivation.target` (`systemd-tmpfiles-resetup`: домашние каталоги новых пользователей) | `upstream.userborn` |
| `Type=idle` ждёт конца загрузки (до 5 с); строки s6-rc не печатаются на консоль, пока на её терминале getty; перезапуск getty после выхода ~110 мс | `upstream.shadow`, `upstream.sssd-ldap` |
| getty на tty2+ запускаются при переключении на консоль (как autovt у logind), `X-WaitForVT=` | `upstream.rtkit` |
| активация D-Bus через юнит на сессионной шине; `Type=dbus` у пользовательских сервисов; `DBUS_SESSION_BUS_ADDRESS` у менеджера пользователя и в сессии (`pam_s6_env`) | `upstream.pass-secret-service`, `upstream.lomiri-gallery-app.*` |
| менеджер пользователя в PAM-сессии `systemd-user` (`makeHomeDir`), вход ждёт его запуска, как pam_systemd | `upstream.sssd-ldap`, `user-services` |
| slurm без systemd (`IgnoreSystemd=yes` в cgroup.conf) | `upstream.slurm` |
| AppArmor-профили (`apparmorRulesFromClosure`) в режиме `replace`: библиотеки подмены разрешены в `abstractions/base` | `upstream.mumble` |
| сервис за сокетом (не `Accept=yes`) запускается при первом обращении, а не при загрузке, как у systemd | `boot`, `upstream.lxd-image-server`, `upstream.kubo` |
| `systemd-run`: `-p StandardOutput=/StandardError=/WorkingDirectory=/Environment=/User=/Group=`, `--working-directory DIR`, `--user --machine=USER@` | `upstream.benchexec` (до вызова D-Bus API) |
| `RootDirectory=`: каталог становится корнем пространства имён сервиса (`nsenter -m` видит то же, что сервис); команды с `+` выполняются в нём с привязками и `ReadWritePaths=`, но без остальных ограничений, как в systemd 260 | `upstream.aesmd`, `sandbox` |
| пользовательские юниты из пакетов профиля (`$XDG_DATA_DIRS/systemd/user`); `PartOf=` у пользовательских юнитов | `upstream.ayatana-indicators` |
| `systemctl show -p Environment`, `systemctl --user --machine=USER@ is-enabled` без запущенного менеджера | `upstream.aesmd`, `upstream.atuin-programs` |
| группа `systemd-journal` (её называют в `SupplementaryGroups=`); `systemd-run -p EnvironmentFile=` | `upstream.alloy`, `upstream.atticd` |
| циклы `Requires=`/`BindsTo=` без `After=` рвутся по неупорядоченному ребру (сокеты cockpit `BindsTo=cockpit.service`); система без Nix (`nix.enable = false`) собирается и в режиме `replace` | `upstream.without-nix` |
| ISO (`nix-build -A iso`): загрузка по BIOS и UEFI со знаком NixithOS, живая система, `nixos-generate-config` + `nixos-install` на GPT с systemd-boot, загрузка установленного | вручную в QEMU (16.10) |
| ISO с dwl (`nix-build -A isoDwl`): Calamares со своим брендингом, «Erase disk» на GPT/UEFI, установленная система входит в dwl; kpmcore ищет программы и в `/run/current-system/sw` (pkgs/overlay.nix) | вручную в QEMU (16.10) |
| графический ISO (`nix-build -A isoGraphical`): LXQt на labwc, Calamares стартует сам, панель с плагинами (хеши путей в UTF-16 переписываются при замене, `pkgs/replace-direct-dependencies.nix`) | вручную в QEMU (17.10) |
| `journalctl -g` по тексту сообщения (без учёта регистра, если нет заглавных), код 1 без совпадений; `-t` по имени | `upstream.mumble` |

## Заведомо не работает

| что | почему |
|---|---|
| `networking.useNetworkd`, `systemd.network.*` | нет systemd-networkd; опция принудительно выключена, работает скриптовая сеть |
| `services.resolved`, `boot.initrd.systemd` (и всё, что на нём: systemd-repart в initrd, swap-random-encryption), `systemd.sysusers` (как реализация) | своих замен нет; опции на месте, включённость принудительно `false` |
| тесты, проверяющие сам systemd (`systemd-networkd*`, `systemd-nspawn`, `systemd-machinectl`…) | это не init |
| тесты с `curl` ≥ 8.22 и cookie-файлом для хоста без точки (engelsystem) | curl отбрасывает такие cookie и без этого дерева |
| ferm (legacy `ip6tables`) | в ядре 6.18 из nixpkgs нет `ip6_tables` ни модулем, ни встроенным; без этого дерева так же |
| тесты с `requiredSystemFeatures = [ "uid-range" ]` (evcc и подобные) | нужен `auto-allocate-uids` в Nix хоста |
| `services.journald.upload` (systemd-journal-upload; victorialogs) | функция journald |
| тесты на `systemd.network.*` (rkvm) | нет systemd-networkd |
| `system.etc.overlay` (userborn-static) | требует `boot.initrd.systemd` |
| контейнеры `containers.*` (rstp, ndppd) | nspawn |
| программы, которые говорят с самим systemd по D-Bus (`org.freedesktop.systemd1`: временные юниты, scope с делегированием cgroup — benchexec через pystemd) | API менеджера systemd; на шине сеанса с GNOME есть его часть — `GetUnit`, `Start/Stop/RestartUnit`, `ResetFailed`, окружение ([systemd1-bus](../../pkgs/systemd-shim/systemd1-bus.py)), этого хватает gnome-session 50 |
| тесты функций systemd: pstore, coredump, sysusers, repart | это не init |

## Не сделано

| что | состояние |
|---|---|
| seccomp-директивы (`SystemCallFilter=`, `RestrictAddressFamilies=`, `MemoryDenyWriteExecute=`, `RestrictNamespaces=`…), `PrivateUsers=`, `ProtectProc=`, `RootImage=` | не применяются; у какого юнита — в `report.txt` базы |
| `.automount` | юнит пропускается, запись в отчёте |
| экземпляр шаблона, которого нет в конфигурации (`systemctl start foo@new`) | не запускается; на этом стоит cockpit (`cockpit-wsinstance-https@ХЭШ.socket`). Собираются те, что названы в зависимостях, и те, у которых есть свой каталог drop-in (`gnome-session@gnome.target.d`) |
| точка доступа connman (`connmanctl tether wifi`) | DNS-прокси connman не может занять порт 53 на интерфейсе tether; не разобрано |
| аварийная оболочка при сбое загрузки | нет |
| `nixos-rebuild` как команда | не проверялось |
| контейнеры (`boot.isContainer`, nspawn) | не проверялось |

## Отличия в поведении

- `DynamicUser=`: пользователь не исчезает после остановки сервиса (запись в
  `/etc/passwd` остаётся; при `users.mutableUsers = false` её уберёт следующая
  активация, а сервис допишет заново при старте), и числовой id — из диапазона
  systemd (61184–65519), выбранный по имени, а не свободный на момент старта.
- `EnvironmentFile=` с относительным путём отбрасывается с предупреждением,
  как в systemd.
- `Type=exec`: готовность — сразу после запуска главного процесса; того, что
  исполняемый файл успел загрузиться, нет. Порядок «после kissattach» у
  `axlisten` поэтому иногда проигрывает гонку.

- `After=` на долгоживущий сервис, который не смог запуститься: зависимые
  ждут конца загрузки и стартуют вторым проходом, а не сразу.
- После перезапуска сервиса супервизором `ExecStartPost=` выполняется снова,
  как и в systemd; а вот `foo-hooks` (место `ExecStop=`) остаётся «поднятым».
- `systemctl stop` не меняет состояние в s6-rc: сервис остановлен, но
  `s6-rc -a list` его по-прежнему показывает (`s6-rc diff` это видит).
- Логи — текстовые файлы; структурных полей журнала нет.
- С elogind менеджер пользовательских сервисов живёт в cgroup сессии
  пользователя (у elogind иерархия плоская, владельца процесса он знает только
  через сессию); без сессии — в `user.slice/user-UID.slice/user@UID.service`,
  как у systemd. Пока он там, сессия после выхода может оставаться `closing`
  (при linger).
- Логи пользовательских сервисов — в `~/.local/state/s6`; у пользователя без
  домашнего каталога — в каталоге состояния его менеджера.
- Под нагрузкой (несколько VM на одной машине) kubo и emacs-daemon иногда не
  укладываются в таймауты тестов; по одному проходят.
- Загрузка медленнее systemd там, где разом стартуют десятки юнитов на одном
  процессоре: каждый проходит через bash-runtime. В VM с одним vCPU адреса
  интерфейсов появляются примерно на секунду позже, чем сервисы без
  зависимостей от сети; тесты, которые сразу после загрузки обращаются к
  другой машине, не дожидаясь сети (vsftpd, mosquitto), иногда проигрывают
  эту гонку.
- `.link`: `[Match]` с `Virtualization=`, `Architecture=`, `Credential=` и
  подобным файл не выбирает (проверить нечем); из `[Link]` не применяются
  политики (`NamePolicy=`, `MACAddressPolicy=` — имена даёт eudev) и редкие
  ключи вроде каналов и колец сетевой карты, о чём строка в syslog.
- Сессия, в которой остались чужие процессы, на cgroup v2 может остаться в
  `closing`: у elogind нет уведомления «группа опустела».
- Режим `replace`: программы содержат код, который ходит в systemd
  (`sd_notify`, `sd_login_*`, …), и он работает на elogind; того, чего в
  elogind нет (`sd_bus_*` к сервисам systemd и подобное), система при сборке
  не пропустит.

## Тесты nixpkgs (`upstream.*`)

`nix-build -A upstream.<имя>` (1105 тестов доступны, режим `replace`).
Проходят: haproxy, memcached, unbound, nats, doas, atd, rsync, rsyncd, tinyproxy,
chrony, sudo, openssh (с `startWhenNeeded`), nginx, bind, knot, dovecot,
postfix, redis, samba, stunnel, lighttpd, etcd, nsd, zookeeper. Не проходят по
причинам вне этого дерева: `locale` и `console` (в nixpkgs этой ревизии
`vconsoleConf` интерполируется как функция), `consul`, `vault-dev` (unfree),
`telegraf` (нужен `auto-allocate-uids` в Nix), `keymap` (X11). Не проходят из-за
того, что тест проверяет именно systemd: `kea` (`systemd-networkd-wait-online`),
`fail2ban` (читает journald), `systemd-confinement` (`confinement.enable`
собирает корень из замыкания, а у нас `setpriv` внутри него нет).
