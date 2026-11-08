#!@ash@
set -eu
if [ "$#" -ne 2 ] || [ "$1" != run ]; then
    printf '%s\n' 'usage: unit-runtime run SERVICE' >&2
    exit 2
fi
case "$2" in
    ''|.*|*[!a-zA-Z0-9_.-]*) printf '%s\n' 'unit-runtime: invalid service name' >&2; exit 2 ;;
esac
service=/etc/unit-runtime/services/$2
if [ ! -x "$service" ]; then
    printf 'unit-runtime: service not found: %s\n' "$2" >&2
    exit 1
fi
exec "$service"
