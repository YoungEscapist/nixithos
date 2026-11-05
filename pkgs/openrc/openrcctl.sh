#!@shell@
# openrcctl - what systemctl, switch-to-configuration and unit-runtime ask of
# the service manager, put to OpenRC: dinitctl's commands (as unit-rc has them
# for runit), over rc-service and the state OpenRC keeps in /run/openrc.
#
#   openrcctl [-p SOCKET] [--quiet] COMMAND [options] [SERVICE]
#
#     list                              "[{+}     ] name" for what is started,
#                                       "[{ }<<   ] name" for what is being
#                                       started, "[     {-}] name" for the rest
#     status SERVICE
#     start [--no-wait] SERVICE         with what it needs; if it is being
#                                       started by someone else, waits for that
#     stop [--force] [--ignore-unstarted] [--no-wait] SERVICE
#                                       with what needs it
#     restart [--force] SERVICE         and what needs it
#     reload SERVICE                    (nothing: a script is read whenever it
#                                       runs)
#     unload SERVICE                    (nothing)
#     rescan                            the services in /run/units/.db have
#                                       changed: OpenRC reads the dependencies
#                                       again
#
# -p names the control socket of the others; OpenRC has none.

PATH=@path@
export PATH
rc_service=@openrc@/sbin/rc-service
rc_update=@openrc@/sbin/rc-update
SVCDIR=/run/openrc
SCRIPTS=/run/units/.db/openrc/init.d

quiet=0
while [[ ${1-} == -* ]]; do
  case $1 in
    -p) shift ;;
    --quiet|-q) quiet=1 ;;
    *) break ;;
  esac
  shift
done
cmd=${1-}
[[ -n $cmd ]] && shift

force=0 ignore=0 nowait=0 name=
for arg; do
  case $arg in
    --force|-f) force=1 ;;
    --ignore-unstarted) ignore=1 ;;
    --no-wait) nowait=1 ;;
    -*) ;;
    *) name=$arg ;;
  esac
done

# the state of one service: started, starting, stopping, inactive, or stopped
svc_state() {
  local s
  for s in started starting stopping inactive; do
    [[ -e $SVCDIR/$s/$1 || -L $SVCDIR/$s/$1 ]] && { echo "$s"; return; }
  done
  echo stopped
}

# The switch holds descriptor 9 as its transaction lock. OpenRC launches
# services as children of rc-service, so do not pass that lock to daemons:
# otherwise the next switch waits for the lifetime of the new service.
# The caller retains its own descriptor until the transaction is complete.
rcs() {
  if (( quiet )); then
    EINFO_QUIET=yes "$rc_service" "$@" 9>&-
  else
    "$rc_service" "$@" 9>&-
  fi
}

# wait while someone else starts or stops it (at most five minutes)
settle() {
  local n=0
  while (( n < 3000 )); do
    case $(svc_state "$1") in
      starting|stopping) sleep 0.1; n=$(( n + 1 )) ;;
      *) return 0 ;;
    esac
  done
}

case $cmd in
  list)
    declare -A st=()
    f=
    for s in started starting stopping inactive; do
      for f in "$SVCDIR/$s"/*; do
        [[ -e $f || -L $f ]] && st[${f##*/}]=$s
      done
    done
    out=
    for f in "$SCRIPTS"/*; do
      n=${f##*/}
      [[ -e $f ]] || continue
      case ${st[$n]-} in
        started|inactive) out+="[{+}     ] $n"$'\n' ;;
        starting) out+="[{ }<<   ] $n"$'\n' ;;
        stopping) out+="[{ }>>   ] $n"$'\n' ;;
        *) out+="[     {-}] $n"$'\n' ;;
      esac
    done
    # (whoever reads it may stop reading: grep -q)
    trap '' PIPE
    printf '%s' "$out" 2> /dev/null
    exit 0
    ;;
  status)
    [[ -n $name ]] || { echo "openrcctl: status: which service?" >&2; exit 1; }
    state=$(svc_state "$name")
    echo "Service: $name"
    echo "State: $state"
    "$rc_service" "$name" status 2>&1 | sed 's/^/  /'
    ;;
  start)
    [[ -n $name ]] || { echo "openrcctl: start: which service?" >&2; exit 1; }
    if (( nowait )); then
      ( setsid "$0" --quiet start "$name" > /dev/null 2>&1 < /dev/null & )
      exit 0
    fi
    settle "$name"
    [[ $(svc_state "$name") == started ]] && exit 0
    rcs "$name" start
    rc=$?
    if (( rc )); then
      # (it came up while this waited for the lock, or still goes on)
      settle "$name"
      [[ $(svc_state "$name") == started ]] && rc=0
    fi
    exit $rc
    ;;
  stop)
    [[ -n $name ]] || { echo "openrcctl: stop: which service?" >&2; exit 1; }
    if (( nowait )); then
      ( setsid "$0" --quiet stop --force --ignore-unstarted "$name" > /dev/null 2>&1 < /dev/null & )
      exit 0
    fi
    settle "$name"
    if [[ $(svc_state "$name") == stopped ]]; then
      (( ignore )) && exit 0
      echo "openrcctl: $name is not started" >&2
      exit 1
    fi
    rcs "$name" stop
    rc=$?
    if (( rc )); then
      settle "$name"
      [[ $(svc_state "$name") == stopped ]] && rc=0
    fi
    exit $rc
    ;;
  restart)
    [[ -n $name ]] || { echo "openrcctl: restart: which service?" >&2; exit 1; }
    settle "$name"
    if [[ $(svc_state "$name") == stopped ]]; then
      rcs "$name" start
    else
      rcs "$name" restart
    fi
    exit $?
    ;;
  reload|unload)
    exit 0
    ;;
  rescan)
    "$rc_update" -u > /dev/null 2>&1
    exit $?
    ;;
  *)
    echo "usage: openrcctl [-p SOCKET] [--quiet] list | status | start | stop | restart | reload | unload | rescan [SERVICE]" >&2
    exit 1
    ;;
esac
