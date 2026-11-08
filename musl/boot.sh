#!/bin/sh
# This is the real root filesystem, embedded in the initramfs. Only BusyBox
# applets are used here; dinit replaces this shell as PID 1.
export PATH=/run/current-system/bin:/bin:/sbin
export HOME=/root
export SHELL=/bin/ash
export TERM=linux
umask 022

fail() {
    echo "NixithOS musl: $*" >/dev/console
    exec /bin/ash </dev/console >/dev/console 2>&1
}

if [ "${1:-}" != --root-mounted ]; then
    mount -t proc proc /proc || fail 'cannot mount /proc'
    mount -t sysfs sysfs /sys || fail 'cannot mount /sys'
    mount -t devtmpfs devtmpfs /dev || fail 'cannot mount /dev'

    # The same image can boot entirely in RAM or use an installed root. A disk
    # root must already contain this rootfs, including its Nix store closure.
    for module in @kernelModules@; do
        modprobe "$module" || echo "NixithOS musl: could not load $module" >/dev/console
    done
    root_spec=
    root_type=ext4
    root_flags=rw
    for argument in $(cat /proc/cmdline); do
        case "$argument" in
            root=/dev/*|root=LABEL=*|root=UUID=*) root_spec=${argument#root=} ;;
            root=*) fail 'root= requires /dev/PATH, LABEL=NAME, or UUID=VALUE' ;;
            rootfstype=*) root_type=${argument#rootfstype=} ;;
            rootflags=*) root_flags=${argument#rootflags=} ;;
        esac
    done
    if [ -n "$root_spec" ]; then
        attempts=0
        root_device=
        while [ "$attempts" -lt 10 ]; do
            case "$root_spec" in
                /dev/*) root_device=$root_spec ;;
                *) root_device=$(findfs "$root_spec" 2>/dev/null) ;;
            esac
            [ -b "$root_device" ] && break
            sleep 1
            attempts=$((attempts + 1))
        done
        mount -t "$root_type" -o "$root_flags" "$root_device" /mnt || fail "cannot mount $root_device"
        [ -x /mnt/init ] || fail 'installed root has no executable /init'
        mount --move /proc /mnt/proc || fail 'cannot move /proc'
        mount --move /sys /mnt/sys || fail 'cannot move /sys'
        mount --move /dev /mnt/dev || fail 'cannot move /dev'
        exec switch_root /mnt /init --root-mounted
        fail 'cannot switch to installed root'
    fi
fi
mkdir -p /dev/pts /dev/shm
ln -sf /proc/self/fd /dev/fd
ln -sf /proc/self/fd/0 /dev/stdin
ln -sf /proc/self/fd/1 /dev/stdout
ln -sf /proc/self/fd/2 /dev/stderr
mount -t devpts -o mode=0620,gid=5 devpts /dev/pts || fail 'cannot mount /dev/pts'
mount -t tmpfs -o mode=1777,nosuid,nodev tmpfs /dev/shm || fail 'cannot mount /dev/shm'
mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs /run || fail 'cannot mount /run'
mkdir -p /run/units /run/lock /run/log /run/user
active_system=$(readlink -f /nix/var/nix/profiles/system)
if [ ! -d "$active_system/etc/dinit.d" ] || [ ! -d "$active_system/etc/unit-runtime/services" ] || [ ! -r "$active_system/etc/hostname" ] || [ "$(cat "$active_system/etc/nixith-musl" 2>/dev/null)" != 1 ]; then
    echo 'NixithOS musl: invalid system profile; using image generation' >/dev/console
    active_system=@system@
fi
ln -s "$active_system" /run/current-system
ln -sfn "$active_system/etc/dinit.d" /etc/dinit.d
ln -sfn "$active_system/etc/unit-runtime/services" /etc/unit-runtime/services
hostname "$(cat "$active_system/etc/hostname")"

# The copied closure must be registered before Nix can use its store paths as
# build inputs. This bootstrap file belongs to the image, not a host database.
if [ -x /bin/nix-store ]; then
    registration_checksum=$(sha256sum /etc/nix/registration) || fail 'missing Nix image registration'
    registration_checksum=${registration_checksum%% *}
    if [ "$(cat /nix/var/nix/.image-registration 2>/dev/null)" != "$registration_checksum" ]; then
        /bin/nix-store --init || fail 'cannot initialize the Nix store'
        /bin/nix-store --load-db < /etc/nix/registration || fail 'cannot register the image closure'
        printf '%s\n' "$registration_checksum" > /nix/var/nix/.image-registration.new || fail 'cannot record Nix registration'
        mv /nix/var/nix/.image-registration.new /nix/var/nix/.image-registration || fail 'cannot commit Nix registration'
    fi
fi

ip link set lo up || fail 'cannot bring up loopback'
@networkSetup@

echo 'NixithOS musl: starting dinit' >/dev/console
exec @dinit@/bin/dinit --system -d /etc/dinit.d boot
