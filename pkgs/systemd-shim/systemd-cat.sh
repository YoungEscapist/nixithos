#!@shell@
# systemd-cat - send a command's output (or stdin) to the system log.

PATH=@path@:$PATH
RUNTIME=@runtime@

ident= prio=
while (( $# )); do
  case $1 in
    -t|--identifier) shift; ident=$1 ;;
    --identifier=*) ident=${1#*=} ;;
    -p|--priority) shift; prio=$1 ;;
    --priority=*) prio=${1#*=} ;;
    --stderr-priority=*|--level-prefix=*|--namespace=*) ;;
    --) shift; break ;;
    -*) ;;
    *) break ;;
  esac
  shift
done

log=(logger ${ident:+-t "$ident"} ${prio:+-p "$prio"})
if (( $# == 0 )); then exec "${log[@]}"; fi
[[ -z $ident ]] && log=(logger -t "${1##*/}" ${prio:+-p "$prio"})
exec > >(exec "${log[@]}") 2>&1
exec "$@"
