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
