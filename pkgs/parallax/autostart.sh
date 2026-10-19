#!/bin/sh
# What NixithOS's Parallax session runs alongside the compositor
# (parallax-session starts this with the compositor's pid just before it
# execs it): the wallpapers (plx-wall), the clipboard's history (cliphist,
# Super+C) and the notifications (mako).  What the repository's
# launch_native.sh does for a session out of the source tree.
#
# Each waits for the compositor's socket: a NEW one, since the file of a
# previous session's socket can still be there, and plx-wall started on it
# would crash in a loop before the new compositor even listened.
#
# Before that, `--prepare SHARE` (run first, in the foreground) gives a new
# user what makes the first session look right: the configuration in the
# language of the system (the compositor itself would write the English one),
# and wallpapers out of the system's, one of them chosen (plx-wall alone
# shows none until one is picked: a grey screen).
if [ "$1" = --prepare ]; then
    share=$2
    # PLX_SYSTEM_WALLPAPERS, PLX_DEFAULT_WALLPAPER (../../modules/desktop/desktops.nix)
    # shellcheck disable=SC1091
    [ -r /etc/parallax/session.env ] && . /etc/parallax/session.env
    conf=${XDG_CONFIG_HOME:-$HOME/.config}
    if [ ! -e "$conf/parallax/config.lua" ] && [ -d "$share" ]; then
        case ${LC_ALL:-${LC_MESSAGES:-$LANG}} in
            ru*) src=$share/default_config.ru.lua ;;
            *) src=$share/default_config.lua ;;
        esac
        [ -f "$src" ] || src=$share/default_config.lua
        # (the Russian file is the same configuration with Russian comments,
        # and it too says lang = "en": a Russian system gets the Russian
        # interface as well)
        case $src in
            *.ru.lua) lang=ru ;;
            *) lang=en ;;
        esac
        mkdir -p "$conf/parallax" &&
            sed "s/^set{ lang = \"en\" }/set{ lang = \"$lang\" }/" "$src" > "$conf/parallax/config.lua"
    fi
    # notifications below the bar, in its greys (mako reads only the user's
    # own file)
    if [ ! -e "$conf/mako/config" ] && [ -f /etc/xdg/mako/config ]; then
        mkdir -p "$conf/mako" && cp /etc/xdg/mako/config "$conf/mako/config" &&
            chmod u+w "$conf/mako/config"
    fi
    wall=$conf/plx-wall
    if [ ! -e "$wall/current" ] && [ ! -e "$wall/wallpapers.json" ]; then
        list=
        first=
        # (paths word-split on purpose: the store's and /run's have no spaces)
        # shellcheck disable=SC2046,SC2086
        for f in ${PLX_DEFAULT_WALLPAPER:-} $(
            for dir in ${PLX_SYSTEM_WALLPAPERS:-}; do
                find -L "$dir" -maxdepth 2 -type f 2>/dev/null
            done | sort
        ); do
            case $f in
                *.png | *.jpg | *.jpeg | *.webp) ;;
                *) continue ;;
            esac
            [ -f "$f" ] || continue
            case $list in *"\"$f\""*) continue ;; esac
            [ -n "$first" ] || first=$f
            list="$list${list:+,}\"$f\""
        done
        if [ -n "$first" ]; then
            mkdir -p "$wall" &&
                printf '[%s]\n' "$list" > "$wall/wallpapers.json" &&
                printf '%s\n' "$first" > "$wall/current"
        fi
    fi
    exit 0
fi

pid=$1
start=$(date +%s)
sock=
i=0
while [ $i -lt 300 ] && [ -z "$sock" ]; do
    kill -0 "$pid" 2>/dev/null || exit 0
    for s in "$XDG_RUNTIME_DIR"/wayland-*; do
        [ -S "$s" ] || continue
        [ "$(stat -c %Y "$s")" -ge "$start" ] || continue
        sock=${s##*/}
        break
    done
    [ -n "$sock" ] || sleep 0.1
    i=$((i + 1))
done
[ -n "$sock" ] || exit 0

export WAYLAND_DISPLAY="$sock"
# (a DISPLAY inherited from elsewhere sent GTK dialogs to another X server)
unset DISPLAY
# services the bus starts on demand get their environment from it
dbus-update-activation-environment WAYLAND_DISPLAY >/dev/null 2>&1 || true

children=
trap 'kill $children 2>/dev/null' EXIT INT TERM

# the clipboard's history: text and pictures (PrtScr puts the shot there)
wl-paste --type text --watch cliphist store >/dev/null 2>&1 &
children="$children $!"
wl-paste --type image --watch cliphist store >/dev/null 2>&1 &
children="$children $!"

# notifications (unless something else already answers for them)
if ! dbus-send --session --print-reply --dest=org.freedesktop.DBus / \
        org.freedesktop.DBus.NameHasOwner string:org.freedesktop.Notifications 2>/dev/null |
        grep -q 'boolean true'; then
    mako >/dev/null 2>&1 &
    children="$children $!"
fi

# the wallpapers, raised again whenever they fall, for as long as the
# compositor lives
while kill -0 "$pid" 2>/dev/null; do
    plx-wall >/dev/null 2>&1 || true
    sleep 0.5
done
