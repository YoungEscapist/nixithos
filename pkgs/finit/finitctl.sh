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
# Finit acknowledges IPC requests before the service transition finishes.
# Bound synchronous calls; callers doing batches can explicitly use --no-wait.
wait_state() {
  local goal=$1 state deadline=$((SECONDS + 90))
  while (( SECONDS < deadline )); do
    state=$("$ctl" -j status "$native") || return $?
    state=$(jq -r '.status' <<< "$state") || return $?
    case $goal:$state in
      up:running)
        # The process exists before notify:s6 reports readiness.
        "$ctl" cond get "service/$native/ready" && return 0
        ;;
      up:done|down:stopped|down:halted|down:done) return 0 ;;
      up:failed|up:crashed|up:missing|up:dead|up:conflict) return 1 ;;
    esac
    sleep 0.1
  done
  echo "finitctl: timed out waiting for $native to become $goal" >&2
  return 1
}
case $cmd in
  list)
    data=$("$ctl" -j status) || exit $?
    rows=$(jq -r '.[] | [.identity, .status] | @tsv' <<< "$data") || exit $?
    declare -A states=()
    while IFS=$'\t' read -r native status; do
      [[ -n $native ]] && states[$native]=$status
    done <<< "$rows"
    while IFS=$'\t' read -r atom native; do
      status=${states[$native]-}
      case $status in
        running|done) printf '[{+}     ] %s\n' "$atom" ;;
        waiting|starting) printf '[{ }<<   ] %s\n' "$atom" ;;
        *) printf '[     {-}] %s\n' "$atom" ;;
      esac
    done < /run/units/.db/finit-names.tsv
    ;;
  status)
    native=$(lookup "$name") || exit 1
    "$ctl" status "$native"
    ;;
  start|stop|restart)
    native=$(lookup "$name") || exit 1
    if (( nowait )); then
      "$ctl" "$cmd" "$native"
    elif [[ $cmd == restart ]]; then
      "$ctl" stop "$native" && wait_state down &&
        "$ctl" start "$native" && wait_state up
    else
      "$ctl" "$cmd" "$native" || exit $?
      if [[ $cmd == stop ]]; then wait_state down; else wait_state up; fi
    fi
    ;;
  reload|unload) exit 0 ;;
  rescan) "$ctl" reload ;;
  *) echo "finitctl: unsupported command $cmd" >&2; exit 1 ;;
esac
