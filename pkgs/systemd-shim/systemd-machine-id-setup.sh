#!@shell@
# systemd-machine-id-setup - make sure /etc/machine-id exists.

PATH=@path@:$PATH
RUNTIME=@runtime@

root=
for a in "$@"; do
  case $a in
    --root=*) root=${a#*=} ;;
    --print) cat "$root/etc/machine-id" 2>/dev/null; exit 0 ;;
  esac
done
if [[ ! -s $root/etc/machine-id ]]; then
  umask 022
  tr -d - < /proc/sys/kernel/random/uuid > "$root/etc/machine-id" || exit 1
fi
exit 0
