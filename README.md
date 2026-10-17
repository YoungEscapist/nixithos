# NixithOS

<p align="center"><img src="branding/nixithos.png" alt="NixithOS" width="420"></p>

NixOS, в котором нет systemd: PID 1 — `s6-linux-init`, сервисами управляет
`s6-rc`, устройствами — `eudev`, логами — `s6-log`.

Это не переписанный дистрибутив, а слой поверх обычного nixpkgs
(сейчас — ветка `nixos-26.05`). Конфигурация остаётся конфигурацией NixOS:
те же `configuration.nix`, те же опции, те же модули сервисов. Меняется то,
что стоит под ними.

```nix
{ pkgs, ... }: {
  networking.hostName = "box";
  services.openssh.enable = true;
  users.users.alice.isNormalUser = true;

  # свой сервис описывается так же, как в NixOS
  systemd.services.hello = {
    wantedBy = [ "multi-user.target" ];
    serviceConfig.ExecStart = "${pkgs.hello}/bin/hello";
  };
}
```

```console
$ cat /proc/1/comm
s6-svscan
$ s6-rc -a list | head -3
basic.target
dbus
dbus-log
```

## Как это устроено

В NixOS каждый демон, точка монтирования и шаг загрузки описан юнитом
systemd — так написаны две тысячи модулей. Выбрасывать их было бы глупо,
поэтому здесь `systemd.services.*` остаётся **моделью данных**: юниты
генерируются тем же кодом, что и в NixOS, а потом компилятор `unitc`
(работает только при сборке системы) превращает каталог юнитов в базу
сервисов s6-rc.

| юнит | что получается в s6-rc |
|---|---|
| `foo.service`, `Type=oneshot` | oneshot `foo` |
| `foo.service`, остальные типы | longrun `foo` + его логгер `foo-log` |
| `foo.target` | oneshot-пустышка: точка синхронизации |
| `foo.mount`, `foo.swap` | oneshot с `mount` / `swapon` |
| `foo.socket` | oneshot: сокет привязывается заранее и лежит в `s6-fdholder`, сервис забирает его при каждом старте |
| `foo.timer` | longrun с планировщиком (`OnCalendar=` и остальное) |
| `dev-….device` | oneshot, ждущий появления устройства |

Процесс каждого сервиса запускает `unit-runtime`: окружение, `User=`,
каталоги (`RuntimeDirectory=` и т. п.), лимиты, capabilities, учётные
данные, готовность (`Type=notify`, `forking`, `dbus`), `Restart=`,
`ExecStartPre/Post`, `ExecStop`, своя cgroup на сервис.

### Две базы вместо одной

У s6-rc один вид зависимости: «запустить после, требовать, перезапускать
вместе». У systemd порядок (`After=`) и требование (`Requires=`) — разные
вещи. Если превратить весь порядок в зависимости, то добавление любого
таймера при `nixith switch` перезапускало бы пол-системы, потому что
всё стоит «после `basic.target`», а тот — «после `timers.target`».

Поэтому из одних и тех же сервисов собираются две базы:

- **`compiled-boot`** — весь порядок записан зависимостями. На ней система
  загружается: s6-rc поднимает всё в правильном порядке и настолько
  параллельно, насколько порядок позволяет.
- **`compiled`** — зависимости только настоящие (`Requires=`, `BindsTo=`).
  На неё система переходит сразу после загрузки (`s6-rc-update`, без единого
  перезапуска) и на ней живёт.

Порядок между юнитами, которые потом запускаются или останавливаются вместе
(`systemctl start`, переключение конфигурации, выключение), восстанавливается
«рангом» — числом, которое растёт вдоль каждого `After=`.

Подробнее — в [docs/design.md](docs/design.md).

## Что вместо чего

| было | стало |
|---|---|
| systemd (PID 1) | s6-linux-init → s6-svscan |
| юниты, `systemctl` | s6-rc; `systemctl` остался как тонкая обёртка |
| journald, `journalctl` | s6-log в `/var/log/s6/<сервис>/`, syslog через s6-socklog; `journalctl -u …` читает эти каталоги |
| systemd-udevd | eudev; `.link`-файлы (MTU, MAC, имя) применяет `unit-link` |
| systemd-hostnamed | `hostnamectl` и маленький `hostname-agent` для пользователей вроде dhcpcd |
| systemd-tmpfiles, sysusers | sd-tools (те же правила `tmpfiles.d`) |
| systemd в initrd | скриптовый initrd NixOS с eudev |
| dbus-broker | dbus-daemon |
| systemd-logind | elogind (`services.elogind.enable`; включается сам, если включён X-сервер, менеджер входа или Wayland-композитор) |
| systemd-timesyncd | свой SNTP-клиент (`unit-sntp`), те же опции `services.timesyncd.*` |
| `PrivateTmp=`, `ProtectSystem=` и подобное | mount-пространство имён, `unit-sandbox` |
| `systemd --user` | один s6-svscan на пользователя, поднимается с первой сессией (PAM) |
| socket activation | сокеты в s6-fdholder (переживают перезапуск сервиса) |
| `switch-to-configuration` | свой, на `s6-rc-update` |
| загрузчики | GRUB, Limine — как были; systemd-boot — `bootctl` и EFI-файлы из пакета systemd, больше ничего оттуда |

## Что делать с systemd в пакетах

systemd не запускается, но пакеты nixpkgs собраны с поддержкой его библиотек
(`libsystemd`, `libudev`). Что с этим делать, решает `s6.systemdPackages`:

| значение | что происходит | цена |
|---|---|---|
| `"replace"` (по умолчанию) | пакеты из кэша как есть, под ними подменены `libsystemd` → `libelogind`, `libudev` → eudev | ничего не компилируется; бинарники содержат неиспользуемый код systemd |
| `"rebuild"` | пакеты собираются без поддержки systemd, `udev` → eudev | кэша для таких вариантов нет: часы компиляции для рабочего стола. Единственный режим, меняющий сами пакеты |
| `"keep"` | ничего | библиотеки systemd остаются в замыкании |

Кроме `keep`, система, в замыкании которой остался systemd, не соберётся.
Исключений нет, кроме загрузчика: если включён `boot.loader.systemd-boot`,
`bootctl` и EFI-файлы берутся из пакета systemd (копией с подправленными
путями, без остального пакета) — это загрузчик, а не init.

## Что с пакетами

Меняется init и всё, что к нему привязано; пакеты остаются теми же. В
режиме `replace` это буквально те же бинарники из кэша.

**Работает как раньше:** всё, что просто запускается демоном или командой, —
то есть почти весь nixpkgs: серверы, базы, браузеры, рабочие столы,
игры, Nix сам. Модули NixOS для них — те же две тысячи, без правок.

**Работает через замену:** то, что обращалось к systemd через его
библиотеки. `sd_notify`, `sd_listen_fds`, `sd_login_*`, D-Bus-службы logind
(polkit, рабочие столы, `libseat`) обслуживает elogind. Из публичного API
`libsystemd` двадцать функций elogind не имеет (в основном `sd_device_monitor_*`,
`sd_bus_creds_*pidfd*`) и ещё около двухсот — varlink и JSON; на них
программа получит `-ENOSYS` (или `NULL`), а запускаться будет.

**Не работает, потому что это и есть systemd:** `systemd-networkd`,
`resolved`, `machined`, `homed`, `nspawn`, `oomd`, `repart`, `sysupdate`,
`journald` как структурированный журнал, `systemd-cryptsetup` и `initrd` на
systemd. Опции этих модулей на месте (чужие модули их читают), реализации
нет; чем что заменено — таблица выше и [docs/status.md](docs/status.md).
`networking.useNetworkd` принудительно выключается: интерфейсы, адреса и
маршруты из `networking.*` настраивает скриптовая сеть, а ручной
`systemd.network.*` применять некому (будет предупреждение).
Программы, которые *проверяют* состояние systemd (`systemctl is-system-running`,
`busctl`, журнал по полям), получают ответ тонкой обёртки или ошибку.

## nixith: пересборка системы

Систему собирает и переключает `nixith` — вместо `nixos-rebuild` и прочих
`nixos-*` (их в `PATH` больше нет, `nixith` зовёт их сам, где нужно).
Конфигурация лежит в `/etc/nixith` (система, поставленная раньше, переносит
туда `/etc/nixos` при активации и оставляет на старом месте ссылку).

```console
$ sudo nixith switch              # собрать, сделать загрузочной, переключиться
$ sudo nixith boot | test         # только загрузочной / только переключиться
$ nixith build | dry-build        # собрать (./result) / показать, что соберётся
$ nixith build-vm                 # то же в QEMU
$ sudo nixith rollback            # назад на прошлое поколение
$ nixith generations              # поколения системы
$ sudo nixith switch --flake /etc/nixith#box   # flake: nixithConfigurations.box
```

**Пересобрать часть конфигурации, не трогая остальное:**

```console
$ sudo nixith switch --only services.nginx
$ sudo nixith switch --only environment.systemPackages,users.users
$ nixith parts                    # из чего собрана работающая система
```

`--only` берёт путь опции или группы опций. Опции под этими путями получают
те значения, которые им даёт конфигурация *сейчас*; всё остальное — те, что у
работающей системы, даже если в файлах оно уже поменялось. Так можно
поправить и применить одну службу, оставив недоделанные правки в другом месте
файла на потом. Остальное вычисляется в те же пути в store, поэтому
`switch-to-configuration` его не трогает (проверено: после
`--only services.openssh.ports` у новой системы другой только
`etc/ssh/sshd_config`, а `sw`, ядро и initrd — те же пути).

Как это устроено ([lib/nixith.nix](lib/nixith.nix)): каждая система, собранная
`nixith`, хранит в `nixith/source.json` копию каталога конфигурации (или
flake), из которого собрана, с деревом и nixpkgs, которыми вычислялась, — это
часть её замыкания. Частичная сборка вычисляет эту основу как была и
добавляет «слой»: определения опций под `--only` из текущей конфигурации, выше
всех определений основы. Новые частичные сборки ложатся слоями поверх
(`nixith parts` их показывает), полная `nixith switch` начинает с новой
основы. Значит, в каталоге конфигурации не стоит держать секреты: он
копируется в store, как и всё, на что конфигурация ссылается путём.

Остальные инструменты — подкоманды или `nixith-*`: `nixith install`
(`nixith-install`), `nixith generate-config` (пишет в `/etc/nixith`),
`nixith enter`, `nixith option`, `nixith version`, `nixith edit`.

## Flakes

Работают в обоих видах, и `nixpkgs` остаётся вашим:

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  inputs.nixithos.url = "github:…/nixithos";
  inputs.nixithos.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { nixpkgs, nixithos, ... }: {
    # штатный nixosSystem плюс один модуль
    nixosConfigurations.box = nixpkgs.lib.nixosSystem {
      modules = [ nixithos.nixosModules.default ./configuration.nix ];
    };

    # или то же через готовую обёртку; `nixith --flake .#box2` ищет сначала
    # nixithConfigurations, потом nixosConfigurations
    nixithConfigurations.box2 = nixithos.lib.system {
      modules = [ ./configuration.nix ];
    };
  };
}
```

`nixosModules.default` отключает через `disabledModules` те модули nixpkgs,
которые и есть интеграция с systemd, возвращает их опции (без реализации) и
добавляет модули этого дерева. Оверлей с пакетами дерева (`pkgs.nixithos`)
модуль подключает сам через `nixpkgs.overlays`; если вы задаёте
`nixpkgs.pkgs` готовым набором, добавьте в него `nixithos.overlays.default`.

Ревизия nixpkgs должна быть та, под которую написан список модулей
(`modules/parts.nix` проверяет это при вычислении и говорит, что именно
сдвинулось).

## Имя и знак

Система называет себя NixithOS: `NAME=NixithOS`, `ID=nixithos` в
`/etc/os-release`, а значит, и в меню загрузчика, в приветствии консоли и у
всех, кто читает этот файл. Машина без имени зовётся `nixith`, конфигурация
лежит в `/etc/nixith`, система в store — `nixith-system-…`, живой
пользователь ISO — `nixith`, команды — `nixith …`. Осталось только
`ID_LIKE=nixos`: это не имя, а сведения для программ («ведёт себя как NixOS»),
по ним они узнают раскладку системы. Знак —
[branding/nixithos.png](branding/nixithos.png), он же символами в
[branding/logo.txt](branding/logo.txt):

```
                     .
                     :
             ____    |    ____
                 \   |   /
                  \  |  /
        _____      \   /      _____
             \      \ /      /
              \   ___|___   /
              /  /       \  \
             /  /         \  \
. --- ------<  <           >  >------ --- .
             \  \         /  /
              \  \_______/  /
              /      |      \
        _____/      / \      \_____
                   /   \
                  /  |  \
             ____/   |   \____
                     |
                     :
                     '
```

`fastfetch` показывает его сам: в системе есть
`/etc/xdg/fastfetch/config.jsonc` с этим логотипом (свой
`~/.config/fastfetch/config.jsonc` пользователя главнее). Сам fastfetch
ставится опцией `nixithos.branding.fastfetch.install = true;` (сборка без
необязательных зависимостей) или как угодно иначе. `nixithos.branding.enable =
false;` возвращает имя NixOS.

Знак есть и картинками (`nixithos.branding.artwork`): значок `nixithos` в
`share/icons/hicolor` и `share/pixmaps` (на него ссылается `LOGO=nixithos` в
os-release) и фоны меню загрузки ISO.

## ISO: живая система и установка

```console
$ nix-build -A iso                  # result/iso/nixithos-26.05…-x86_64-linux.iso
$ nix-build -A isoGraphical         # …-graphical-…: dwl и Calamares
```

Консольный — штатный минимальный установочный образ NixOS
([images/iso.nix](images/iso.nix)) на этом дереве: грузится по BIOS
(syslinux) и UEFI (GRUB), в меню — знак NixithOS, дальше живая система с
автовходом `nixith` (без пароля). Установка:

```console
# nixith generate-config --root /mnt
# nixith install
```

`nixith install` ставит NixithOS тем же путём, что `nixith switch`
([lib/nixith.nix](lib/nixith.nix)), так что установленная система с первого
поколения умеет `nixith switch --only …`. Проверено в QEMU: разметка GPT,
systemd-boot, загрузка установленной системы.

Графический — [images/iso-graphical.nix](images/iso-graphical.nix): живая
система с dwl на tty1 (автовход `nixith` без пароля), и вместе с ней
открывается графический установщик — Calamares со знаком и слайдами NixithOS
([pkgs/calamares-nixithos](pkgs/calamares-nixithos)); закрытый установщик
снова запускается из списка программ (Super+P, «Install NixithOS»).

Шаги установщика: язык и часовой пояс, раскладка, пользователь, затем то,
что будет стоять в системе:

| шаг | выбор | в конфигурации |
|---|---|---|
| Desktop | dwl, Parallax, GNOME, KDE Plasma, Hyprland, niri или без стола | `nixithos.desktop.<имя>.enable` |
| Login | ly, greetd (tuigreet) или консоль | `nixithos.desktop.displayManager` |
| Shell | Bash, Zsh, fish, Nushell | `users.users.<имя>.shell` |
| Bootloader | systemd-boot, Limine, GRUB, rEFInd | `boot.loader.*` |

дальше несвободное ПО и разметка. На BIOS загрузчик всегда GRUB: остальные
три здесь только для UEFI. Без менеджера входа автовход идёт консольный, а
dwl сам стартует при входе на tty1; остальные столы тогда запускаются руками.
Конфигурацию установщик пишет в `/etc/nixith` и ставит через `nixith install`.
Parallax лежит на образе (в кэше NixOS его нет), прочие столы скачиваются из
кэша при установке — нужна сеть.

У каждого варианта на этих шагах — снимок настоящей NixithOS
([branding/screenshots](branding/screenshots)): столы с открытыми окнами,
оболочки в терминале, ly/greetd/консоль, меню загрузчиков. Сняты в QEMU
(столы и оболочки — с конфигурации вроде `configs.desktops`, меню — тестом
вроде `tests/bootloader.nix` с долгой паузой меню); niri — вложенным окном во
весь экран, раз на программном рендере он сам не рисует. Пока идёт установка,
листаются 17 советов (`show.qml`: `nixith`, поколения, службы и журналы,
пакеты, столы, оболочки); клик или стрелки — следующий.

Столы целиком проверены в QEMU (`nix-build -A configs.desktops.vm`, вход
`yarik`/`yarik`): ly на tty1; Parallax, GNOME, Plasma (Wayland) и Hyprland
входят и рисуют рабочий стол; niri стартует целиком, но на программном
рендере QEMU рисовать отказывается («software EGL renderers are skipped») —
нужна видеокарта. Блокировка экрана GNOME 50 требует GDM, с ly она выключена
(GNOME сам пишет об этом при входе).

## Собрать и посмотреть

Нужен Nix. Всё остальное он скачает или соберёт сам.

```console
$ nix-build -A configs.vm.vm        # система в QEMU
$ ./result/bin/run-six-vm           # вход: root / root

$ nix-build -A tests.boot           # тесты: каждая загружает VM и проверяет
$ nix-build -A tests.units          #   поведение юнитов по одному свойству
$ nix-build -A tests.switch         #   переключение конфигурации на лету
$ nix-build -A tests.login          #   вход с консоли и по ssh
$ nix-build -A tests.replace        #   режим replace: кэш + подменённые библиотеки
$ nix-build -A tests.elogind        #   сессии и loginctl
$ nix-build -A tests.user-services  #   пользовательские сервисы, systemctl --user
$ nix-build -A tests.bootloader     #   GRUB (BIOS и UEFI), Limine, systemd-boot, rEFInd

$ nix-build -A upstream.openssh     # штатный тест из nixpkgs против этого дерева
$ nix-build -A upstream.networking.scripted.static   # имена — как у nixosTests
```

Свою конфигурацию:

```nix
# system.nix
(import /path/to/nixithos { }).eval { modules = [ ./configuration.nix ]; }
```

```console
$ nix-build system.nix -A config.system.build.toplevel
```

или через flake — см. выше.

## На живой системе

```console
$ systemctl status sshd             # привычные команды работают
$ systemctl restart nginx
$ journalctl -u nginx -f

$ s6-rc -a list                     # а это родные
$ s6-svstat /run/service/sshd
$ tail -F /var/log/s6/sshd/current
$ cat /run/uncaught-logs/current    # лог загрузки и всего, у чего нет своего логгера
```

`systemctl stop X` останавливает один сервис, как в systemd.
`s6-rc -d change X` — сервис и всё, что его требует.

## Чего пока нет

См. [docs/status.md](docs/status.md). Коротко: фильтры системных вызовов
(`SystemCallFilter=`, `RestrictAddressFamilies=` — остальная песочница
работает, список непримёненного в `report.txt` базы), `.automount`,
экземпляры шаблонов, создаваемые на ходу (`systemctl start foo@new`, если ни
одна зависимость и ни один drop-in его не называют), контейнеры.

## Лицензия

MIT, как у nixpkgs. Файлы `modules/system/boot/stage-1*` и `stage-2-init.sh`
взяты из nixpkgs и изменены.
