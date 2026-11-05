#!@shell@
# Small dinit-command adapter for the shared unit runtime, using Finit IPC.
PATH=@path@
export PATH
ctl=@initctl@
while [[ ${1-} == -* ]]; do
  case $1 in -p) shift ;; esac
  shift
done
cmd=${1-}; [[ $# -gt 0 ]] && shift
name= nowait=0
for arg; do
  case $arg in --no-wait) nowait=1 ;; -*) ;; *) name=$arg ;; esac
done
lookup() {
  local atom native
  while IFS=$'\t' read -r atom native; do
    [[ $atom == "$1" ]] && { echo "$native"; return 0; }
  done < /run/units/.db/finit-names.tsv
  return 1
}
case $cmd in
  list)
    data=$("$ctl" -j status) || exit $?
    while IFS=$'\t' read -r atom native; do
      status=$(jq -r --arg name "$native" '.[] | select(.identity == $name) | .status' <<< "$data")
      case $status in
        running|done) printf '[{+}     ] %s\n' "$atom" ;;
        waiting|starting) printf '[{ }<<   ] %s\n' "$atom" ;;
        *) printf '[     {-}] %s\n' "$atom" ;;
      esac
    done < /run/units/.db/finit-names.tsv
    ;;
  status) "$ctl" status "$(lookup "$name")" ;;
  start|stop|restart)
    native=$(lookup "$name") || exit 1
    "$ctl" "$cmd" "$native"
    ;;
  reload|unload) exit 0 ;;
  rescan) "$ctl" reload ;;
  *) echo "finitctl: unsupported command $cmd" >&2; exit 1 ;;
esac
