# Устройство

## Имя

Система называет себя NixithOS (`modules/branding.nix`): это штатные
`system.nixos.distroName`/`distroId`/`vendorName` NixOS, так что имя видят
`/etc/os-release` (`ID=nixithos`, `ID_LIKE=nixos`), меню загрузчиков,
приветствие консолей и всё, что читает os-release. Знак — `branding/`:
картинка, она же символами (`logo.txt`) и с метками цветов для fastfetch
(`logo-fastfetch.txt`), которому система даёт `/etc/xdg/fastfetch/config.jsonc`.
`nixithos.branding.enable = false` возвращает имя NixOS.

## Слой поверх nixpkgs

Дерево nixpkgs не форкнуто. `lib/nixpkgs.json` закрепляет ревизию, модули
NixOS импортируются из неё по пути. `modules/module-list.nix` берёт штатный
список модулей и делит его на три части:

- **оставленные** — почти все (сервисы, пользователи, сеть, загрузчики…);
- **только опции** — модули, которые и есть интеграция с systemd
  (`system/boot/systemd.nix`, journald, logind, networkd, …). Их опции читают
  и задают другие модули, поэтому объявления остаются, а половина `config`
  выбрасывается. Делается это без копирования: модуль импортируется как
  функция, и из результата берутся только `options` и `imports`;
- **заменённые целиком** — скриптовый initrd (`stage-1`), который взят из
  nixpkgs и переведён на eudev.

Свои модули лежат в `modules/` и дают реализацию там, где она нужна.

Обновить nixpkgs — поменять ревизию в `lib/nixpkgs.json` и прогнать тесты.
Если модуль из списков переименовали, сборка остановится с понятным
сообщением.

## Загрузка

```
ядро → initrd (stage 1: eudev, корень) → $toplevel/init (stage 2)
     → s6-linux-init → s6-svscan (PID 1) + rc.init
```

**Stage 2** (`modules/system/boot/stage-2-init.sh`) — тот же сценарий, что в
NixOS: специальные ФС, `/nix/store` только для чтения, скрипт активации.
Дальше он задаёт имя хоста, создаёт `/etc/machine-id` и запускает
`s6-linux-init` там, где NixOS запускает systemd.

Базовый каталог s6-linux-init создаётся `s6-linux-init-maker` при сборке и
лежит в store. В store нельзя хранить FIFO, поэтому две FIFO из его образа
`/run` (логгер и shutdownd) вырезаются при сборке и создаются stage 2 прямо
перед `exec`; сам s6-linux-init запускается с `-N` (не перемонтировать
`/run`) и копирует остальной образ поверх.

**rc.init** делает три шага:

1. `s6-rc-init` на базе `compiled-boot` и `s6-rc -u change default` —
   загрузка с полным порядком.
2. `s6-rc-update` на базу `compiled` — ни один сервис при этом не
   перезапускается (зависимости только убираются).
3. Если что-то упало, не будучи никому обязательным, то всё, что стояло
   «после» него, на первом шаге не запустилось. Теперь, когда порядок больше
   не зависимость, оно запускается.

Пока идёт загрузка, существует `/run/units/.booting`.

## Юниты → s6-rc

`modules/compat/units.nix` генерирует каталог юнитов штатной библиотекой
NixOS (`nixos/lib/systemd-lib.nix`): юниты из модулей, юниты из
`systemd.packages`, drop-in'ы, алиасы, каталоги `.wants`. Отличие от NixOS
одно — из пакета systemd ничего не копируется. Стандартные target'ы и
ранние сервисы, которые systemd поставляет сам, определены в
`modules/compat/base-units.nix`.

`pkgs/unitc/unitc.py` читает этот каталог и пишет:

| файл | что это |
|---|---|
| `source-boot/`, `source/` | исходники s6-rc для двух баз |
| `unit-data/<юнит>` | данные юнита: переменные и функции bash для `unit-runtime` |
| `index.tsv` | юнит → тип, ранг, имена сервисов s6-rc, что запускать вместе с ним |
| `ranks.tsv` | ранг каждого сервиса s6-rc |
| `switch.tsv` | хеши и флаги для `switch-to-configuration` |
| `devices.tsv` | какие юниты запускать при появлении устройства |
| `manifest.json` | то же, что выше, одним файлом |
| `report.txt` | всё, что проигнорировано или упрощено |

Имя сервиса в s6-rc — имя юнита без `.service` (`sshd`), у остальных типов
полное (`multi-user.target`). Ранние сервисы носят имена юнитов systemd
(`systemd-udevd.service`), чтобы на них попадали частичные определения из
модулей NixOS и чужие `After=`; в s6 они называются по-человечески
(`udevd`) — это задаёт `X-S6-Name=`.

Свои директивы (все в стиле `X-…`, systemd их игнорирует):

- `X-S6-Name=` в `[Unit]` — имя на стороне s6;
- `X-Replace=yes` в `[Unit]` — определение полное, одноимённый юнит из
  пакета не подмешивать;
- `X-NotifyFd=N` в `[Service]` — демон сам сообщает о готовности по
  протоколу s6 в дескриптор N (`s6-socklog -d 3`, `dbus-daemon
  --print-address=3`);
- `X-Fsck=yes` в `[Mount]` — проверить ФС перед монтированием.

### Что делает unit-runtime

Скрипт `run` каждого сервиса — одна строка: `unit-runtime run <данные>`.
Он:

1. очищает окружение и собирает то, что описано юнитом (`Environment=`,
   `EnvironmentFile=`, `HOME`/`USER` при `User=`);
2. проверяет `Condition*=`/`Assert*=`;
3. заводит cgroup `/sys/fs/cgroup/units/<имя>` и применяет лимиты
   (`MemoryMax=`, `TasksMax=`, …);
4. создаёт `RuntimeDirectory=` и родственные, раскладывает
   `LoadCredential=`;
5. выполняет `ExecStartPre=`;
6. запускает основной процесс через `setpriv`/`prlimit`/`nice` (пользователь,
   группы, capabilities, `NoNewPrivileges=`, лимиты), передавая сокеты как
   `LISTEN_FDS`;
7. сообщает s6 о готовности тогда, когда её признал бы systemd: сразу
   (`simple`), по `READY=1` (`notify` — слушает `unit-notify`), когда демон
   отделился (`forking`), когда имя появилось на шине (`dbus`) — и только
   после `ExecStartPost=`. У `notify-reload` сокет уведомлений живёт всё
   время работы сервиса: о каждой перезагрузке демон сообщает туда же, а
   sshd ещё и проверяет, что сокет на месте.

Командные строки и `Environment=` unitc разбирает, как systemd: кавычки
снимаются и посреди слова (`-port="8888"` — это `-port=8888`, на этом
стоит модуль cfssl).

`finish` выполняет `ExecStopPost=`, добивает оставшееся в cgroup, убирает
каталоги и решает по `Restart=`, перезапускать ли: код 125 говорит
s6-supervise «больше не запускать». `StartLimitBurst=` тоже считается здесь.

`ExecStop=` у долгоживущего сервиса некуда повесить: у s6 нет хука «перед
остановкой». Поэтому для таких юнитов появляется oneshot `<имя>-hooks`,
зависящий от сервиса; его `down` и есть `ExecStop=`.

Состояние каждого юнита лежит в `/run/units/<юнит>/` (`state`, `result`).

Строки, которые systemd пишет в журнал про сам юнит («Started ….»,
«Stopped …», «Reloaded …», «Failed with result …»), runtime пишет в
`/run/units/<юнит>/journal`; `journalctl -u` склеивает их с логом службы по
времени. `OnFailure=` и `OnSuccess=` исполняются при смене состояния:
перечисленные юниты запускаются через `systemctl --no-block start`.

Вывод разового задания идёт только в его каталог `/var/log/s6/<юнит>/` (как у
systemd — в журнал, а не на экран); на консоль попадает лишь строка о провале.

`s6.logging.echoFailures` пишет хвост лога упавшего юнита в `/dev/kmsg`, и он
оказывается на консоли — для тестовых VM, где больше негде прочитать, почему.

### Песочница

`PrivateTmp=`, `PrivateDevices=`, `PrivateNetwork=`, `PrivateIPC=`,
`ProtectHostname=`, `ProtectSystem=` (`yes`, `full`, `strict`),
`ProtectHome=` (`yes`, `read-only`, `tmpfs`), `ReadOnlyPaths=`,
`ReadWritePaths=`, `InaccessiblePaths=`, `BindPaths=`, `BindReadOnlyPaths=`,
`TemporaryFileSystem=`, `ProtectKernelTunables=`, `ProtectControlGroups=`
исполняются по-настоящему. `unitc` собирает аргументы в `U_SANDBOX`; для
каждой команды юнита (`ExecStartPre=`, `ExecStart=`, `ExecStop=`…) runtime
добавляет перед `setpriv` префикс

```
unshare --mount --propagation private [--net] [--uts] [--ipc] --
        unit-sandbox АРГУМЕНТЫ -- команда…
```

`unit-sandbox` — bash: делает монтирования в новом пространстве имён и
исполняет команду. Устройства: свой `/dev` из tmpfs с привязанными
`null zero full random urandom tty`, `pts`, `shm`. «Только для чтения» —
`mount -o remount,bind,ro` по каждой точке монтирования под путём;
`ProtectSystem=strict` делает так со всеми, кроме `/dev`, `/proc`, `/sys`, а
`ReadWritePaths=` и каталоги юнита (`RuntimeDirectory=`, `StateDirectory=`,
`CacheDirectory=`, `LogsDirectory=`) возвращают записываемыми.
`DynamicUser=yes` подразумевает `ProtectSystem=strict`, `ProtectHome=read-only`
и `PrivateTmp=`, как в systemd.

`ProtectKernelModules=`, `ProtectKernelLogs=`, `ProtectClock=` снимают
соответствующие capabilities из ограничивающего набора.

`RootDirectory=` (и `MountAPIVFS=`, `RootDirectoryStartOnly=`) — тот же
`unit-sandbox` с `--root`: все пути директив (`TemporaryFileSystem=`,
`PrivateTmp=`, `ProtectSystem=`, назначения `BindPaths=`) понимаются внутри
корня, источники привязок — хостовые. Сам `chroot` делает `unit-chroot`
после `setpriv`: на этот миг у процесса есть CAP_SYS_CHROOT в ambient, потом он
снимается. Так работает, например, `tor.service`.

Чего нет: `SystemCallFilter=`, `RestrictAddressFamilies=`,
`MemoryDenyWriteExecute=`, `RestrictNamespaces=` и прочего на seccomp, а также
`PrivateUsers=`, `ProtectProc=`, `RootImage=`; они остаются в `report.txt`.
Не существующий путь не отказ, а предупреждение (systemd отказывает).

### Порядок, требования и отказы

- `After=` учитывается только относительно юнитов, которые и так будут
  запущены (входят в загрузку или подтягиваются самим юнитом) — как в
  systemd, где порядок действует в пределах одной транзакции.
- Юнит, который упал, но никому не обязателен (`Wants=`, а не
  `Requires=`), не должен тянуть за собой остальных. Oneshot в таком случае
  отвечает s6-rc «успех», а отказ пишет в лог и в состояние. Обязательный —
  отвечает честно, и требующие его не запускаются.
- Циклы порядка systemd разрывает на ходу; `s6-rc-compile` их не принимает.
  `unitc` разрывает их сам, начиная с самого слабого ребра, и пишет об этом
  в отчёт.
- Юнит с `Requires=` на несуществующий юнит запустить нельзя (systemd тоже
  откажется) — он исключается, с записью в отчёте.

### Сокеты

`.socket` — oneshot, который привязывает сокеты (`unit-socket`) и кладёт их
в `s6-fdholder` (сервис `unit-fdholder`). Сервис забирает их при каждом
старте, так что перезапуск сервиса не закрывает сокет. Ленивого первого
запуска нет: сервис сокета запускается сразу. Но остановленный (или
завершившийся) сервис запускается снова, когда на сокет что-то пришло, как
у systemd: это делает узел `<сокет>-activate` (`unit-runtime
socket-activate`), который ждёт, пока сервис не остановится (`s6-svwait`),
потом — входящего на сокетах (`unit-socket-wait`, `poll` по копиям из
fdholder, ничего с них не забирая), и зовёт `systemctl start`. Тест kubo
останавливает ipfs и ждёт, что следующий запрос поднимет его снова.

### Accept=yes

Сокет с `Accept=yes` — это «один процесс на соединение» (`sshd.socket`,
`rsyncd.socket`): шаблонный юнит `foo@.service` запускается на каждое
соединение под именем `foo@СЧЁТЧИК-ЛОКАЛЬНЫЙ-УДАЛЁННЫЙ.service`.

- Сокеты по-прежнему привязывает oneshot `foo.socket` и кладёт в
  `s6-fdholder`. Рядом появляется longrun `foo.socket-accept`: он берёт
  сокеты оттуда, `unit-accept` принимает соединения и на каждое запускает
  `unit-runtime accept-conn`.
- Шаблон компилируется один раз, с экземпляром-заглушкой
  `ACCEPTINSTANCEPLACEHOLDER` (только буквы — проходит экранирование без
  изменений); `accept-conn` подставляет настоящее имя через `sed` и
  запускает как обычный процесс сервиса со своей cgroup.
- Соединение приходит как дескриптор 3 (`LISTEN_FDS=1`) или, при
  `StandardInput=socket`, как stdin/stdout. `REMOTE_ADDR` и `REMOTE_PORT`
  выставляются, как у systemd. `MaxConnections=` (64) ограничивает число
  одновременных.

### Таймеры

`.timer` — долгоживущий `unit-timer`: разбирает `OnCalendar=` (включая
списки, диапазоны, шаги, дни недели, `~` для конца месяца, часовой пояс),
`OnBootSec=`, `OnUnitActiveSec=` и остальные, `Persistent=`,
`RandomizedDelaySec=`. По срабатыванию запускает сервис как разовую задачу
(`unit-runtime job`), не трогая состояние s6-rc; пока задача идёт, второй
раз не запустит.

### Устройства

Зависимость от `dev-….device` превращается в oneshot, который ждёт появления
узла (до 90 с, как у systemd).

Юниты, «желаемые» устройством (`wantedBy = [ "sys-subsystem-net-devices-eth0.device" ]`
— так NixOS настраивает адреса), обрабатываются двумя путями:

- при загрузке такое устройство входит в транзакцию как разовая проверка
  после `udevadm settle`: есть — его юниты стартуют в своём месте порядка,
  нет — не стартуют и никого не задерживают;
- после загрузки сервис `device-watch` слушает события udev и запускает
  юниты при появлении устройства. Он же исполняет свойство `SYSTEMD_WANTS`
  из правил udev (`bluetooth.target`, `sound.target`).

## Переключение конфигурации

`$toplevel/bin/switch-to-configuration` (тот же контракт, что в NixOS):

1. сравнивает `switch.tsv` работающей и новой базы;
2. останавливает изменившиеся юниты (старыми определениями), кроме
   `stopIfChanged = false`;
3. выполняет скрипт активации;
4. `s6-rc-update` на новую базу, с пометкой `restart` для изменившихся;
   исчезнувшие сервисы он останавливает сам;
5. запускает новое по рангам, перезагружает `reloadIfChanged`.

Поскольку живая база содержит только настоящие требования, перезапуск
затрагивает изменившийся юнит и то, что его `Requires=`, — и ничего больше.

В конце, как systemd, `switch-to-configuration` «запускает активные цели»:
`systemctl start default.target`. Для цели shim запускает заново всё, что она
хочет и что не работает, что бы ни думал о нём s6-rc: упавшие службы (поэтому
переключение на всё ещё сломанную конфигурацию падает и второй раз),
разовые задания, остановленное вручную.

Разовые задания (`Type=oneshot` без `RemainAfterExit=`) после загрузки
«неактивны», и systemd при `switch` запускает их заново, если определение
изменилось (так работают `restartTriggers` у `nginx-config-reload` и
перезагрузки правил). Здесь то же: такие юниты собираются в список `rerun` и
выполняются после остального, в порядке рангов.

## Чего systemd не просили, а он делал

Как PID 1 systemd сам монтирует служебные ФС, поднимает `lo`, задаёт имя
хоста, поднимает лимит открытых файлов. В модулях NixOS этого нет, потому
что не нужно. Здесь это `modules/system/early.nix` и stage 2.

## Пакеты и systemd

Сам systemd не запускается ни в одном режиме. Вопрос в другом: его
библиотеки (`libsystemd`, `libudev`) и пакет целиком — в замыкании системы
или нет. Выбирает `s6.systemdPackages`. Меняется только init и то, что к
нему привязано; пакеты остаются пакетами nixpkgs, и по умолчанию это те же
бинарники из кэша.

### `"replace"` (по умолчанию)

Пакеты берутся из кэша как есть, а библиотеки под ними подменяются
(`system.replaceDependencies`, `modules/no-systemd.nix`):

| было | стало |
|---|---|
| `libsystemd.so.0` (`systemdLibs`, `systemdMinimal`) | своя `libsystemd.so.0`: нужна `libelogind.so.0`, определяет те же версии `LIBSYSTEMD_*`; чего в elogind нет (около двадцати функций sd-bus/sd-device/sd-event, varlink и JSON) — заглушки с `-ENOSYS` / `NULL`; список строится при сборке по `nm` оригинала |
| `libudev.so.1` | `libudev` из eudev |
| пакет `systemd` целиком | shim с подставленными библиотеками |
| `systemd-*-dev` (заголовки, `.pc`) | пустышка с одним `systemd.pc` |

Подмена идёт внутри бинарников по путям в store, поэтому у замены имя той же
длины (добивается подчёркиваниями; длина считается по имени пути в store, а
не по `name` деривации: у `systemd-260.5` выход `dev` называется
`systemd-260.5-dev`). Элогинд и eudev берутся из набора без systemd — иначе
замена зависела бы от самой себя через PAM и D-Bus.

Две проверки при сборке системы:

- **до подмены** — по `nm`/`readelf` у каждой программы замыкания
  сверяется, что все импортированные `sd_*` и `udev_*` есть в заменяющих
  библиотеках: такие программы связаны с немедленным связыванием и иначе
  не запустились бы;
- **после** — `system.forbiddenDependenciesRegexes` по замыканию
  подменённой системы.

Проверки работают через import-from-derivation: оценка конфигурации сначала
собирает систему. Это цена режима; взамен ничего не компилируется.

Ещё три тонкости:

- На x86_64 то же самое делается для 32-битного systemd (`pkgsi686Linux`):
  его тянут 32-битные программы (pulseaudio с `support32Bit`, Steam,
  32-битные драйверы графики). Подмены, оригинала которых в замыкании нет,
  отбрасываются заранее, по `closureInfo` системы, — поэтому 32-битные
  части собираются только там, где нужны, а replaceDependencies не
  предупреждает о каждой лишней.
- Сервис с `confinement.enable` живёт в корне из путей своего замыкания,
  список которых составлен до подмены: где были библиотеки systemd, в списке
  окажутся их замены, но не то, из чего замены сделаны. Поэтому замены
  добавляются в `confinement.packages` таких сервисов.
- `system.build.toplevelReplacedUnchecked` — подменённая система без
  проверок: если проверка «после» падает, `nix why-depends` на ней
  показывает, кто ещё держится за systemd (`toplevelUnreplaced` — система
  до подмены).

### `"rebuild"`

`pkgs/no-systemd.nix`: большинство пакетов nixpkgs включают поддержку systemd
по условию `lib.meta.availableOn stdenv.hostPlatform systemd` — так
собираются наборы для musl. Оверлей объявляет systemd недоступным, и
поддержка выключается везде сразу; `udev` становится eudev. Сам атрибут
`pkgs.systemd` указывает на shim, чтобы модули, которые берут оттуда
`systemctl` или `systemd-notify`, получили работающие команды.

Цена — бинарный кэш NixOS не содержит таких вариантов: всё, что зависит от
D-Bus, udev, PAM, util-linux, собирается из исходников (для сервера —
минут двадцать, для рабочего стола — часы). Это единственный режим, который
меняет сами пакеты; тест — `tests.rebuild` (в общий набор не входит).

### `"keep"`

Ничего не делать. systemd не работает, но его библиотеки, а кое-где и пакет,
остаются в замыкании.

В режимах кроме `keep` `system.forbiddenDependenciesRegexes` не даст собрать
систему, в замыкании которой оказался systemd.

### Загрузчик systemd-boot

Загрузчик — не init, и его заменять незачем: `boot.loader.systemd-boot`
работает штатным модулем nixpkgs, а ему нужен только `bootctl` (из
`config.systemd.package`) и EFI-файлы рядом с ним. Эти файлы shim берёт из
настоящего пакета systemd (`pkgs/systemd-shim/boot-tool.nix`), но не весь
пакет:

- копируются `bin/bootctl`, `lib/systemd/libsystemd-shared-*.so` (без неё он
  не запускается) и `lib/systemd/boot/efi`;
- в копиях путь исходного пакета заменяется путём копии; имя копии той же
  длины (`boot-tool____`), как и в подмене библиотек, — так `bootctl` находит
  свои EFI-файлы и библиотеку, и в замыкании нет ссылки на systemd;
- у библиотеки обрезан RUNPATH до трёх пакетов: openssl и glibc (с ними она
  слинкована) и util-linux-minimal (оттуда `bootctl` открывает `libblkid`).
  Остальные тридцать — cryptsetup, FIDO2, TPM2, PAM — нужны для того, чего
  загрузчик не делает, а часть из них собрана против `libsystemd`/`libudev`
  и тянула бы systemd в замыкание. Что открывается на самом деле, видно из
  `strace -e openat bootctl … install | status | update`.

Результат в замыкании — около десятка маленьких путей: сам пакет, glibc,
openssl, util-linux (`lib` и `login`), libidn2, libunistring, libxcrypt,
libgcc.

## Пользователи динамических сервисов

systemd выдаёт `DynamicUser=` пользователя на время жизни сервиса и сообщает
о нём всей системе через nss-systemd, так что `chown glance` в `ExecStartPre=`
и `getpwuid()` в демоне работают. Без nss-systemd runtime при первом запуске
дописывает пользователя и группу в `/etc/passwd` и `/etc/group` (под
блокировкой, id из диапазона systemd по имени, при занятом — следующий
свободный). Генерировать их при сборке конфигурации через `users.users`
нельзя: перечисление `systemd.services` из `users.users` замыкается на
`linger-users`, который читает `users.users`.

## Способ подключения

Список модулей разбит в `modules/parts.nix`: остающиеся как есть (`kept`),
оставляемые только как объявления опций (`optionsOnly`), заменённые
целиком (`dropped`) и свои (`ours`). Из него получается два способа
подключения, одинаковых по результату:

- `modules/module-list.nix` — `baseModules` для `lib/eval-config.nix`
  (`nixithos.lib.system`, `(import ./. { }).eval`);
- `modules/default.nix` — один модуль для штатного `nixpkgs.lib.nixosSystem`
  (`nixosModules.default`): `disabledModules` для `optionsOnly` и `dropped`,
  в `imports` — обёртки `optionsOnly` и `ours`.

Сравнение одной и той же конфигурации обоими способами (`toplevel` обоих):
те же файлы, то же замыкание, различаются хэши `system-path` и всего, что
на него ссылается, — из-за порядка в списке `environment.systemPackages`.
Тесты `module` и `module-units` — это `boot` и `units` с узлами, собранными
вторым способом (`moduleMode` в `lib/testing.nix`).

## Запуск во время загрузки и перезапуск самого себя

Две вещи, которые systemd делает очередью заданий, а здесь приходится делать
явно.

**Старт, пока идёт загрузка.** Загрузка — одна транзакция `s6-rc`, и она держит
блокировку базы. Юнит, который в ходе загрузки делает `systemctl start X`
(или таймер, сработавший рано), не может пойти через `s6-rc`; shim запускает
сервис напрямую (`s6-svc -u`), и `s6-rc` о нём не знает. Финальный
`s6-rc-update` заменил бы каталог такого сервиса и убрал его. Поэтому
`rc.init` между транзакцией и переходом на вторую базу находит работающие, но
не числящиеся поднятыми сервисы и говорит `s6-rc -u change`: процесс уже
запущен, меняется только учёт. Чтобы между этим поиском и `s6-rc-update`
ничего не запустилось, `rc.init` держит `/run/units/.switch-lock`
(эксклюзивно), а `systemctl` при таком прямом старте — разделяемо и только до
момента «процесс поднят» (готовности ждёт уже без неё; ждать саму блокировку
больше десяти секунд не станет, чтобы задание внутри чужой транзакции s6-rc
не сцепилось с `rc.init`). Без этого `systemctl start --wait` в самом начале
теста borgbackup попадал в это окно: задание убивалось переходом и
заканчивалось «успешно», ничего не сделав.

**Между концом процесса и итогом.** Пока `./finish` решает, чем кончился
запуск (s6: сервис «down и не ready»), `systemctl` показывает `deactivating`,
а не `inactive`: иначе `start --wait` и `wait_for_unit` принимали этот миг за
успешное завершение.

**Перезапуск изнутри.** `systemctl restart X`, вызванный процессом самого X
(например, `ExecStartPost=` у influxdb2), нельзя выполнить честно: перезапуск
убил бы того, кто его делает. shim узнаёт такой вызов по cgroup
(`/proc/self/cgroup`) и кладёт в каталог состояния файл `restart-requested`.
Runtime читает его в двух местах: после `ExecStartPost=` (запуск завершён —
главный процесс получает сигнал) и в `finish` (перезапуск без `RestartSec=` и
при любом `Restart=`). Если сервис уже работает, shim сам посылает главному
процессу сигнал через `s6-svc -t`.

**Цель таймера — сервис, который остаётся.** Задание `job` для не-oneshot
запускает сервис как `systemctl start` (через `s6-rc`, а если s6-rc считает его
поднятым, а процесса нет — `s6-svc -u`), а не гонит `ExecStart=` в переднем
плане.

## Журнал и консоль

Логов в одном журнале нет: у каждого сервиса свой `s6-log` и каталог в
`/var/log/s6/`. `journalctl` собирает их и строки «Started/Stopped/Reached
target», которые runtime пишет в `/run/units/<юнит>/journal`.

Если `services.journald` просит консоль (`console = "/dev/ttyS0"` или
`ForwardToConsole=yes` + `TTYPath=` в `extraConfig` — так делает
`test-instrumentation` у машин тестов), система делает то же: имя терминала
попадает в `/etc/units/console-log`, логгер каждого сервиса пишет строки и
туда (с именем сервиса впереди), а runtime — свои «Started X.» с префиксом
`systemd[1]:`. На этом держится `wait_for_console_text` в тестах (их
тридцать с лишним); `wait_for_x` ищет «Reached target Current graphical» — это
`graphical-session.target` менеджера пользователя.

Сами логгеры, самый частый вызов runtime (каждый сервис, все сразу на
загрузке), отвечают из первых строк скрипта, не разбирая остальные тысячу
семьсот: bash исполняет скрипт по мере чтения.

## Привилегии команд и песочница

Команда с префиксом `+` в `ExecStartPre=` и других выполняется «с полными
привилегиями»: ни `User=`, ни пространства имён юнита (`ProtectSystem=`,
`PrivateTmp=`, `RootDirectory=`) к ней не применяются, только к остальным.
`wpa_supplicant` пользуется этим, чтобы создать файл в `/etc` до того, как
юнит станет читать его из read-only корня.

Рабочий каталог входится ещё раз после того, как песочница смонтировала всё,
что нужно: иначе он остаётся каталогом под монтированием `ProtectSystem=strict`,
а не самим монтированием, сделанным записываемым (`StateDirectory=`).

Приватный `/dev` получает `/dev/log`: `syslog(3)` должен куда-то идти.

`systemd-inhibit` без elogind блокировать нечем, но пока команда работает,
запись о блокировке лежит в `/run/systemd/inhibit-shim`, и `--list` её
показывает (тест borgbackup ищет там свою).

Привязки (`BindPaths=`, `BindReadOnlyPaths=`) монтируются в порядке путей,
как у systemd, а не в порядке записи: `BindPaths=/etc/wpa_supplicant`
остаётся записываемым под `BindReadOnlyPaths=/etc/`. Привязка внутрь
приватного `/tmp` (`PrivateTmp=` с `BindReadOnlyPaths=/tmp/bird`, тест
flap-alerted) ложится на него, а не под него; к этому моменту путь источника
уже ведёт в приватный каталог, поэтому источник открывается заранее и
монтируется через `/proc/self/fd/N` (с `--no-canonicalize`: иначе `mount`
превращает ссылку обратно в путь).

`UMask=` — для того, что создаёт сама команда. Точки монтирования песочница
создаёт с 022: при `UMask=0077` и `RootDirectory=` (wpa_supplicant) корень
получался непроходимым для пользователя сервиса.

`ProtectSystem=strict` повторяет systemd 260 и в его неочевидных местах
(проверено на штатном NixOS через `systemd-run`): `/home`, `/root`,
`/run/user` остаются записываемыми, ими распоряжается `ProtectHome=`;
`/run` закрыт, но открыт, если у юнита ещё и `ProtectProc=` или
`ProcSubset=pid` (так у nginx, и тест nginx-tmpdir пишет в `/run`).

`BindPaths=` остаётся записываемым и под `ProtectSystem=strict`, который
делает только для чтения всё остальное (у systemd так же; wpa_supplicant
сохраняет конфигурацию через такую привязку). С `RootDirectory=`
`MountAPIVFS=` по умолчанию включён, как у systemd: в корне есть `/proc`,
`/sys`, `/dev`, а с ними `/dev/fd` (на нём держится `<(…)` в скриптах).

`PrivateTmp=` лежит там же, где у systemd:
`/tmp/systemd-private-<boot id>-<юнит>-XXXXXX/tmp` и то же в `/var/tmp`
(тесты ищут его там). Каталоги создаются на первую команду запуска, общие
для всех его команд, и уходят вместе с сервисом; правила tmpfiles
(`x`/`X`, как в `tmp.conf` systemd) не дают очистке `/tmp` их трогать.

`RootDirectory=` входится после `setpriv` (корень, собранный из замыкания,
как у confinement, `setpriv` не содержит), поэтому `unit-chroot` получает
`CAP_SYS_CHROOT` на этот миг: пользователю — как ambient, root — в
ограничивающий набор вместе с `CAP_SETPCAP`, если в наборе юнита их нет; после
chroot они оттуда убираются (`-B`). Иначе root-сервис с пустым
`CapabilityBoundingSet=` (gonic) не входил в свой корень.

`CPUSchedulingPriority=` зажимается в диапазон политики, как в systemd:
`fifo`/`rr` без приоритета получают 1 (freeswitch).

`PAMName=` — главный процесс работает в PAM-сессии. `unit-pam` (C, от root)
открывает сессию (`pam_acct_mgmt`, `pam_setcred`, `pam_open_session`, с
`PAM_TTY` из `TTYPath=`, если у юнита терминал), добавляет окружение модулей
(`XDG_RUNTIME_DIR`, `XDG_SESSION_ID` от elogind) и запускает команду
дочерним процессом; сам остаётся, чтобы закрыть сессию, и передаёт сигналы —
как `(sd-pam)` у systemd. Стоит в цепочке до песочницы и смены пользователя.
На этом держатся киоски `services.cage` и phosh.

## Сети

`networking.useNetworkd` отдавал бы интерфейсы systemd-networkd, которого
здесь нет. Опция принудительно выключена: всё, что описывает `networking.*`
(адреса, маршруты, VLAN, мосты), настраивает скриптовая реализация, как при
выключенной опции; ручной `systemd.network.*` применять некому, о чём
предупреждение.

Исключение — `.link`-файлы (`systemd.network.links`): их читает udev, а не
networkd, и через них NixOS задаёт интерфейсу MTU и MAC-адрес даже в
скриптовой сети (`networking.interfaces.<имя>.mtu`, `.macAddress`), а ещё
Wake-on-LAN. Файлы пишутся в `/etc/systemd/network`, как у upstream, а
применяет их `unit-link` (`pkgs/unit-link`): eudev сам их не знает. Правило
`75-unit-link.rules` на `add` выбирает имя (`Name=`) до правил eudev, на
`add` и `move` применяет остальное: MTU, MAC, псевдоним, длину очереди,
`WakeOnLan=`, автосогласование, скорость, дуплекс, offload'ы. Как в
systemd-udevd, действует первый по имени файл, чей `[Match]` подходит
(`OriginalName`, `Name`, `MACAddress`, `PermanentMACAddress`, `Type`, `Driver`,
`Kind`, `Path`, `Property`, `Host`, `KernelCommandLine`); условие, которое
проверить нечем, делает файл неподходящим, а непримененная настройка
попадает в syslog.

Правило `80-unit-link-keep.rules` оставляет интерфейсу имя, которого никто
не назначил в этом событии (`NAME` = текущее имя), — то, что делает
NamePolicy=keep в systemd-udevd. Без него не срабатывали правила вида
`NAME=="enp1s0"`, а их пишет сам NixOS (`99-ipv6-privacy-extensions.rules`,
временные адреса по интерфейсам).

Имя хоста от DHCP: dhcpcd (`networking.dhcpcd.setHostname`) работает от
своего пользователя в своём пространстве UTS и зовёт `hostnamectl
set-hostname --transient`; при systemd это вызов hostnamed по D-Bus, который
polkit разрешает пользователю dhcpcd. Здесь `hostnamectl` обращается к
`hostname-agent` (`modules/services/hostname.nix`): `s6-ipcserver` на
`/run/hostname-agent/socket`, кто спрашивает — говорит ядро, менять
временное имя можно root и пользователям из `s6.hostname.allowedUsers` (по
умолчанию dhcpcd, если он ставит имя). Сервис есть, только если список не
пуст.

Без имени в конфигурации (`networking.hostName = ""`) stage 2 даёт машине
запасное, как systemd: `DEFAULT_HOSTNAME` из os-release, иначе `localhost`.
Хук dhcpcd переименовывает только машину с таким «ещё не названным»
именем, а `(none)` ядра он таковым не считает. По той же причине брендинг
оставляет `DEFAULT_HOSTNAME=nixos`: с `nixithos` dhcpcd имени бы не менял
и под systemd.

## Шина D-Bus

Системная шина — эталонный dbus-daemon (`modules/services/dbus.nix`):
dbus-broker все запросы активации отдаёт systemd. Сокет он открывает сам и о
готовности сообщает адресом в дескриптор 3.

Без `--systemd-activation` dbus-daemon запускает службу по строке `Exec=` её
файла `.service` (через setuid-помощник, от имени `User=`). Для служб,
которые systemd запускал бы юнитом (`SystemdService=`), этого мало: `Exec=`
там часто заглушка (`/bin/false`) или голая командная строка без настроек
юнита (`wpa_supplicant -u` не знает интерфейсов из
`networking.wireless.interfaces`). Поэтому из всех пакетов
`services.dbus.packages` собирается каталог копий таких файлов, который
dbus-daemon просматривает первым (у одного имени выигрывает первый каталог):
`Exec=` в них — `dbus-unit-activate ЮНИТ ИМЯ` от root, который делает
`systemctl start ЮНИТ` и остаётся, пока имя не появится на шине (активация,
чей процесс кончился раньше, для dbus-daemon провал) или юнит не упадёт.
Сессионные шины пользователей так не делают: там `Exec=` у служб настоящие.

## Время

`services.timesyncd` (по умолчанию включён) реализует `unit-sntp`: маленький
SNTP-клиент (`modules/services/timesyncd.nix`). Читает тот же
`/etc/systemd/timesyncd.conf` (`NTP=`, `FallbackNTP=`, `PollInterval*Sec=`),
запускается пользователем `systemd-timesync` с одной capability
(`CAP_SYS_TIME`), не даёт часам отстать от файла
`/var/lib/systemd/timesync/clock`, на ответ сервера либо ставит время
(отклонение больше 0,4 с), либо подводит `adjtime`, и создаёт
`/run/systemd/timesync/synchronized`. `timedatectl` — shim: `status`, `show`,
`set-timezone`, `list-timezones`, `timesync-status`.

## Сессии: elogind

`services.elogind.enable` (включается сам при `services.xserver`,
`services.displayManager`, `services.greetd`, `services.cage`, sway,
hyprland, niri, labwc, wayfire) — standalone-logind: сессии, места, `loginctl`,
`/run/user/UID`, D-Bus-служба `org.freedesktop.login1`, к которой обращаются
polkit, `libseat` и рабочие столы. Опции — штатные, `services.logind.settings`.

- Служба зовётся `systemd-logind.service` (так её ждут другие юниты), в s6 —
  `elogind`; PAM-модуль `pam_elogind.so` лежит в shim под именем
  `pam_systemd.so`, поэтому правила PAM из nixpkgs подхватывают его сами.
- cgroup v2 в унифицированном режиме: elogind не получает уведомления
  «группа опустела» (release agent'а нет), поэтому он смотрит на лидера сессии.
  Лидер-зомби, которого родитель ещё не подобрал, считался «живым», и сессия
  зависала в `closing`. В elogind поправлен `logind-session.c`: у сессии,
  которая уже останавливается, лидер не проверяется.
- При закрытии последней сессии elogind удаляет `/run/user/UID`. Менеджер
  пользовательских сервисов (ниже) к этому моменту должен быть остановлен,
  поэтому пока он работает, `user-manager` включает пользователю
  *временный* linger, а потом выключает его (`loginctl enable-linger`).

## Пользовательские сервисы

`systemd.user.services|sockets|timers|targets` и `systemctl --user`.
Порядок такой же, как у системных сервисов: `unitc --scope user` компилирует
каталог пользовательских юнитов в **отдельную базу** `<s6-db>/user`
(`compiled-boot` и `compiled`). Дальше для каждого пользователя:

```
PAM (pam_exec: user-manager hook)       — open_session / close_session
        │ ведёт учёт сессий в /run/user-managers/.sessions/UID/
        ▼
/run/user-managers                      — scan-каталог, за который отвечает
        │                                 системный сервис `user-managers`
        ▼
s6-supervise user-UID → user-manager run → setpriv + чистое окружение
        ▼
user-manager session  (от имени пользователя)
        ├─ s6-svscan /run/user/UID/service
        ├─ s6-rc-init, s6-rc -u change default, s6-rc-update (как rc.init)
        └─ при TERM: s6-rc -bDa change, s6-svscanctl -t
```

- Менеджер есть у root и обычных пользователей (UID ≥ 1000), как
  `user@UID.service`; системным учётным записям systemd даёт «лёгкие»
  сессии без менеджера.
- Менеджер поднимается с первой сессией пользователя, переживает короткий
  перелогин (5 с) и останавливается после последней. Останавливает его не
  хук (всё, что хук оставит в фоне, — процесс в cgroup сессии, и сессия не
  закроется), а сервис `user-managers`.
- Остановка: каталог сначала *уходит из scan-каталога* (переименование в
  `.gone-UID`), потом `s6-svc -d`, ожидание, `s6-svc -x`. Иначе s6-svscan
  заново запускает `s6-supervise` для каталога без супервизора, а новый
  супервизор — сервис (файла `down` нет): менеджер «воскресал» без каталога,
  через который ему можно что-то сказать.
- Базы лежат в store, а s6-rc копирует из них каталоги сервисов, где
  супервизорам нужно писать: поэтому менеджер копирует базу в
  `/run/user-managers/.state/UID/db` и открывает на запись.
- Свои файлы менеджер (scan-каталог, s6-rc, копия базы, состояние юнитов)
  держит в `/run/user-managers/.state/UID`, а не в `$XDG_RUNTIME_DIR`: логин-
  менеджер удаляет `/run/user/UID`, как только у пользователя нет сессий и
  linger, а менеджер должен быть достижим, пока его сервисы не остановлены.
  `systemctl --user` находит его там же (`UNIT_USER_STATE`); `--machine=USER@`
  запускает ту же программу заново от имени пользователя.
- Пользователи с linger (`loginctl enable-linger`, `users.users.<имя>.linger`)
  получают менеджер без сессии, с загрузки; `disable-linger` останавливает его
  через несколько секунд. Файлы linger — `/var/lib/elogind/linger` или
  `/var/lib/systemd/linger`; без elogind `loginctl` — маленький shim, который
  умеет только их.
- Окружение: `/etc/set-environment`, `UNIT_SCOPE=user`, `XDG_RUNTIME_DIR`,
  `UNIT_USER_STATE`.
  `systemctl --user import-environment` / `show-environment` работают.
- Сессионная шина — обычный пользовательский сервис `dbus`
  (`dbus-daemon --session --address=unix:path=%t/bus --print-address=3`).
- Сокеты пользователя лежат в его `s6-fdholder` (`unit-fdholder`).
- Без elogind сервис всё равно работает: хук сам создаёт `/run/user/UID` и
  удаляет его при остановке.

## Проверка

`tests/` — тесты на штатном драйвере NixOS (QEMU, `machine.succeed(…)`).
`lib/testing.nix` подменяет в нём список базовых модулей узла.

- `boot` — загрузка, ранние сервисы, логи, управление сервисами, выключение;
- `units` — по одному свойству юнита на сервис: окружение, пользователь,
  хуки, `Restart=`, готовность, порядок, сокеты, таймеры, capabilities…;
- `switch` — переключение туда и обратно, с проверкой, что посторонние
  сервисы не перезапущены;
- `login` — вход с консоли и по ssh между двумя машинами;
- `replace` — режим `"replace"`: нет systemd в замыкании, программы
  работают на подменённых библиотеках;
- `elogind` — сессии, `loginctl`, `/run/user/UID`, закрытие сессии;
- `user-services` — менеджер пользователя: старт с первым входом, сервисы,
  `systemctl --user`, сокеты, шина, окружение, остановка, возврат;
- `sandbox` — каждая директива песочницы по одному юниту, с проверкой
  вердикта изнутри и снаружи;
- `timesync` — часы идут за сервером (свой SNTP-сервер на Python в VM);
- `bootloader` — установленная система: GRUB (BIOS), Limine и systemd-boot
  (UEFI) загружают s6, `switch-to-configuration boot` переустанавливает
  загрузчик, перезагрузка;
- `module`, `module-units` — `boot` и `units` с узлами из штатного списка
  модулей nixpkgs и `nixosModules.default`;
- `rebuild` — `boot` в режиме `"rebuild"`; не входит в общий набор (часы
  сборки).

### Тесты nixpkgs

`nix-build -A upstream.<имя>` запускает штатный тест NixOS против этого
дерева, на бинарях из кэша (`replace`). Список и имена — те же, что у
`nixosTests`: берётся сам `nixos/tests/all-tests.nix`, со всеми аргументами,
которые он даёт тестам (`getPackage` у cassandra, `networkd = false` у
`networking.scripted.*`, группы вроде `postgresql.*`). Все тесты там
собираются через `nixos/lib/testing-python.nix`; `upstreamTree` в
`default.nix` — копия `nixos/tests` рядом со ссылками на остальное дерево
nixpkgs, в которой этот файл заменён переходником на каркас из
`lib/testing.nix` (он подменяет список модулей узла). Так что и `runTest`
из all-tests.nix, и старые тесты (`make-test-python.nix`) строят машины из
этого дерева. Немногие записи, которые идут мимо каркаса (тесты пакетов,
проверки вычисленной конфигурации), проверяли бы штатный NixOS — они
отвергаются при обращении (метка `passthru.nixithos` у своих).

`node.pkgs` (upstream даёт тестам один набор пакетов на все машины, только
для чтения) здесь — набор машин с оверлеем дерева, и не только для чтения:
машины получают пакеты через свои `nixpkgs.*`.
