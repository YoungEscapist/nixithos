#!@shell@
# systemctl - the part of systemctl that scripts and habits rely on, for a
# system whose services are run by s6-rc.
#
# Units are looked up in the index of the live service database (written by
# unitc).  Starting a unit goes through s6-rc, so that what it requires comes
# up with it; stopping and restarting act on that unit alone, like systemd
# does, which is why they talk to the supervisor directly.  `s6-rc -d change`
# is there for whoever wants a service stopped together with everything that
# depends on it.

PATH=@path@:$PATH
RUNTIME=@runtime@
set -u

me=${0##*/}
STATE=/run/units
SCAN=/run/service
LOGDIR=/var/log/s6
LIVE=/run/s6-rc

# s6-rc against the service manager of the scope in use (the system's, or
# with --user the one of the logged-in user)
rc() { s6-rc -l "$LIVE" "$@"; }

die() { echo "$me: $*" >&2; exit 1; }
warn() { echo "$me: $*" >&2; }

# Called once the options are known: which manager, and which database.
discover() {
  local i live
  # (the database is being switched at the end of the boot, and for a moment
  # there are no service directories to look at)
  for i in $(seq 100); do
    [[ -e /run/units/.switching ]] || break
    sleep 0.05
  done
  if (( opt_user )); then
    [[ -n ${XDG_RUNTIME_DIR-} ]] || die "Failed to connect to bus: \$XDG_RUNTIME_DIR is not set"
    export UNIT_SCOPE=user
    # (where the user's manager keeps its files; see user-manager)
    local ust=${UNIT_USER_STATE:-/run/user-managers/.state/$(id -u)}
    UNIT_USER_STATE_DIR=$ust
    STATE=$ust/units
    SCAN=$ust/service
    LIVE=$ust/s6-rc
    LOGDIR=${XDG_STATE_HOME:-$HOME/.local/state}/s6
    # The manager is started by the session and may still be coming up.
    for i in $(seq 150); do
      [[ -e $LIVE/compiled ]] && break
      if [[ ! -d /run/user-managers/user-$(id -u) ]]; then
        # nobody is starting one
        (( i > 3 )) && break
      fi
      sleep 0.1
    done
  fi
  live=$(readlink -f "$LIVE/compiled" 2>/dev/null) || live=
  if [[ -n $live ]]; then
    DB=${live%/*}
  elif (( opt_user )); then
    DB=$(readlink -f /run/current-system/s6-db 2>/dev/null)/user
  else
    DB=$(readlink -f /run/current-system/s6-db 2>/dev/null) || DB=
  fi
}

# Runs the unit runtime for something the user's manager owns.  The unit has
# to see the environment of that manager (the session's: XDG_CONFIG_DIRS, the
# paths of the profiles…), not that of whoever happens to run systemctl, so
# it is the one the manager saved when it started.
run_rt() {
  if (( opt_user )) && [[ -r ${UNIT_USER_STATE_DIR-}/environment ]]; then
    (
      local kv
      while IFS= read -r -d '' kv; do export "$kv"; done < "$UNIT_USER_STATE_DIR/environment"
      exec "$RUNTIME" "$@"
    )
  else
    "$RUNTIME" "$@"
  fi
}

# --------------------------------------------------------------------------
# options

opt_no_block=0 opt_wait=0 opt_quiet=0 opt_all=0 opt_failed=0 opt_value=0 opt_lines=10
opt_signal=TERM opt_props=() opt_type= opt_state= opt_now=0 opt_user=0
opt_no_legend=0 opt_force=0
args=()

# --machine=USER@ (or -M USER@): the user's manager, asked as that user.  It
# is the same program, started again as them with --user.
raw=("$@")
machine=
rest=()
while (( $# )); do
  case $1 in
    -M|--machine) shift; machine=${1-} ;;
    --machine=*) machine=${1#*=} ;;
    -M?*) machine=${1#-M} ;;
    *) rest+=("$1") ;;
  esac
  shift || true
done
set -- ${rest[@]+"${rest[@]}"}
if [[ $machine == *@* && ${machine%%@*} != "" ]]; then
  muser=${machine%%@*}
  if [[ $muser != "$(id -un)" ]]; then
    [[ $(id -u) == 0 ]] || die "Failed to connect to bus: Access denied"
    entry=$(getent passwd "$muser") || die "Failed to connect to bus: no such user $muser"
    IFS=: read -r _ _ muid mgid _ mhome _ <<< "$entry"
    exec setpriv --reuid "$muid" --regid "$mgid" --init-groups \
      env -i PATH="$PATH" HOME="$mhome" USER="$muser" LOGNAME="$muser" \
        XDG_RUNTIME_DIR="/run/user/$muid" UNIT_SCOPE=user \
        UNIT_USER_STATE="/run/user-managers/.state/$muid" \
        "$0" --user "$@"
  fi
  # (the manager is named: whatever the environment says, it is that user's)
  export XDG_RUNTIME_DIR=/run/user/$(id -u)
  opt_user_forced=1
fi
opt_user_forced=${opt_user_forced-0}

while (( $# )); do
  case $1 in
    --no-block) opt_no_block=1 ;;
    -q|--quiet) opt_quiet=1 ;;
    -a|--all) opt_all=1 ;;
    --failed) opt_failed=1 ;;
    --value) opt_value=1 ;;
    --now) opt_now=1 ;;
    --user) opt_user=1 ;;
    --no-legend) opt_no_legend=1 ;;
    -f|--force) opt_force=$(( opt_force + 1 )) ;;
    -n|--lines) shift; opt_lines=${1-10} ;;
    --lines=*) opt_lines=${1#*=} ;;
    -n*) opt_lines=${1#-n} ;;
    -s|--signal) shift; opt_signal=${1-TERM} ;;
    --signal=*) opt_signal=${1#*=} ;;
    -p|--property) shift; opt_props+=(${1//,/ }) ;;
    --property=*) v=${1#*=}; opt_props+=(${v//,/ }) ;;
    -p*) v=${1#-p}; opt_props+=(${v//,/ }) ;;
    # -P: -p … --value
    -P) shift; opt_props+=(${1//,/ }); opt_value=1 ;;
    -P*) v=${1#-P}; opt_props+=(${v//,/ }); opt_value=1 ;;
    -t|--type) shift; opt_type=${1-} ;;
    --type=*) opt_type=${1#*=} ;;
    --state) shift; opt_state=${1-} ;;
    --state=*) opt_state=${1#*=} ;;
    --wait) opt_wait=1 ;;
    --system|--no-pager|--no-ask-password|--plain|--full|-l|--no-wall|--no-reload|--show-types) ;;
    --job-mode=*|--kill-whom=*|--kill-who=*|--output=*|-o*|--root=*|--runtime|--global|--when=*|--message=*) ;;
    -H|--host|-M|--machine|--job-mode|--kill-whom|--kill-who|-o|--output|--root|--when|--message) shift ;;
    -h|--help) args=(help) ;;
    --version) echo "systemctl (s6-rc front-end) 0.1"; exit 0 ;;
    --) shift; args+=("$@"); break ;;
    -*) warn "ignoring unknown option $1" ;;
    *) args+=("$1") ;;
  esac
  shift
done

(( opt_user_forced )) && opt_user=1

# Called as halt/poweroff/reboot?
case $me in
  halt|poweroff|reboot) args=("$me" ${args[@]+"${args[@]}"}) ;;
esac

discover

verb=${args[0]-list-units}
units=("${args[@]:1}")

# --------------------------------------------------------------------------
# the index

declare -A I_KIND I_TYPE I_RANK I_BOOT I_ATOM I_ATOMS I_START ALIAS ATOM_UNIT
# user@UID.service and user-UID.slice: logind's and systemd's way of saying
# "the manager of that user is there"; here, the user's own s6-svscan
declare -A VIRT_UID
index_loaded=0
load_index() {
  (( index_loaded )) && return 0
  [[ -n $DB && -r $DB/index.tsv ]] || die "no service database found (is this system running on s6-rc?)"
  local unit kind type rank boot atom atoms start
  while IFS=$'\t' read -r unit kind type rank boot atom atoms start; do
    if [[ $kind == alias ]]; then
      ALIAS[$unit]=$type
    else
      I_KIND[$unit]=$kind I_TYPE[$unit]=$type I_RANK[$unit]=$rank I_BOOT[$unit]=$boot
      I_ATOM[$unit]=$atom I_ATOMS[$unit]=$atoms I_START[$unit]=$start
      [[ -n $atom && -z ${ATOM_UNIT[$atom]-} ]] && ATOM_UNIT[$atom]=$unit
    fi
  done < "$DB/index.tsv"
  index_loaded=1
}

# resolve NAME -> canonical unit name in $unit; returns 1 if unknown
resolve() {
  load_index
  local name=$1
  case $name in
    *.service|*.socket|*.target|*.mount|*.swap|*.timer|*.path|*.device|*.slice|*.scope|*.automount) ;;
    *) name=$name.service ;;
  esac
  [[ -n ${ALIAS[$name]-} ]] && name=${ALIAS[$name]}
  if [[ -z ${I_KIND[$name]-} && $name == *@*.* ]]; then
    # alias of a template
    local tmpl=${name%%@*}@.${name##*.}
    if [[ -n ${ALIAS[$tmpl]-} ]]; then
      local real=${ALIAS[$tmpl]}
      local inst=${name#*@}
      name=${real%%@*}@$inst
    fi
  fi
  if [[ -z ${I_KIND[$name]-} ]]; then
    case $name in
      user@*.service|user-*.slice)
        local uid=${name#user?}
        uid=${uid%.*}
        if [[ $uid =~ ^[0-9]+$ ]] && getent passwd "$uid" > /dev/null; then
          I_KIND[$name]=virtual I_TYPE[$name]=${name##*.} I_RANK[$name]=0 I_BOOT[$name]=0
          I_ATOM[$name]= I_ATOMS[$name]= I_START[$name]=
          VIRT_UID[$name]=$uid
        fi ;;
    esac
  fi
  unit=$name
  [[ -n ${I_KIND[$name]-} ]]
}

# --------------------------------------------------------------------------
# state

rc_up=
rc_busy=0
load_rc() {
  if rc_up=$(rc -a list 2>/dev/null); then
    rc_up=" ${rc_up//$'\n'/ } "
    rc_busy=0
  else
    # another s6-rc holds the lock (typically: the system is still booting)
    rc_up=
    rc_busy=1
  fi
}

is_rc_up() { [[ $rc_up == *" $1 "* ]]; }

# longrun? (as opposed to something that runs to completion)
is_longrun() {
  [[ ${I_KIND[$1]} == timer || ${I_KIND[$1]} == path ]] && return 0
  [[ ${I_KIND[$1]} == service && ${I_TYPE[$1]} != oneshot ]]
}

svfield() { s6-svstat -o "$2" "$SCAN/$1" 2>/dev/null; }

# sets active_state and sub_state for $1
unit_state() {
  unit_state_raw "$1"
  # A timer went off a moment ago and the job it started has not got round to
  # marking the unit yet: for a caller that waits for the unit (the test
  # driver's wait_for_unit), it is being started, not "inactive with no jobs".
  if [[ $active_state == inactive && ${I_KIND[$1]-} == service && ${1%.service} != *@* ]]; then
    local stamp=/var/lib/units/timers/${1%.service}.timer mt
    if [[ -e $stamp ]]; then
      mt=$(stat -c %Y "$stamp" 2>/dev/null) || mt=0
      if (( EPOCHSECONDS - mt <= 3 )); then
        active_state=activating sub_state=start
      fi
    fi
  fi
  return 0
}

unit_state_raw() {
  local u=$1 st= res=
  if [[ ${I_KIND[$u]-} == virtual ]]; then
    if s6-svstat -o up "/run/user-managers/user-${VIRT_UID[$u]}" 2>/dev/null | grep -q true; then
      active_state=active sub_state=running
    else
      active_state=inactive sub_state=dead
    fi
    return
  fi
  [[ -r $STATE/$u/state ]] && st=$(< "$STATE/$u/state")
  [[ -r $STATE/$u/result ]] && res=$(< "$STATE/$u/result")
  if is_longrun "$u"; then
    local up= ready=
    read -r up ready <<< "$(svfield "${I_ATOM[$u]}" up,ready)"
    [[ -n $up ]] || up=false
    if [[ $up == true ]]; then
      if [[ $st == activating || $st == "" && ${I_KIND[$u]} != timer && ${I_KIND[$u]} != path ]]; then
        active_state=activating sub_state=${res:-start}
      else
        active_state=active sub_state=running
        [[ ${I_KIND[$u]} == timer || ${I_KIND[$u]} == path ]] && sub_state=waiting
      fi
    elif [[ $ready == false && $st == active && $res != exited ]]; then
      # the main process is gone and ./finish has yet to say how it went
      # (down and not ready, to s6): not inactive, and not failed yet
      active_state=deactivating sub_state=stop-post
    elif [[ $st == failed ]]; then
      active_state=failed sub_state=${res:-failed}
    elif [[ $st == active && $res == exited ]]; then
      active_state=active sub_state=exited
    elif [[ $st == activating ]]; then
      # between the end of a run and the next: the restart is under way
      active_state=activating sub_state=${res:-start}
    else
      active_state=inactive sub_state=dead
    fi
    return
  fi
  case ${I_KIND[$u]} in
    target|device)
      if [[ $rc_busy == 0 ]] && is_rc_up "${I_ATOM[$u]}"; then
        active_state=active sub_state=active
        [[ ${I_KIND[$u]} == device ]] && sub_state=plugged
      else
        active_state=inactive sub_state=dead
      fi ;;
    *)
      case $st in
        active) active_state=active sub_state=${res:-exited} ;;
        activating) active_state=activating sub_state=start ;;
        failed) active_state=failed sub_state=${res:-failed} ;;
        *) active_state=inactive sub_state=dead ;;
      esac ;;
  esac
}

main_pid() {
  local u=$1 pid=
  is_longrun "$u" || return 0
  [[ -r $STATE/$u/mainpid ]] && pid=$(< "$STATE/$u/mainpid")
  [[ -z $pid ]] && pid=$(svfield "${I_ATOM[$u]}" pid)
  [[ $pid == -1 ]] && pid=
  printf '%s' "$pid"
}

description() {
  local d=
  case ${I_KIND[$1]-} in
    virtual)
      case $1 in
        user@*) printf 'User Manager for UID %s' "${VIRT_UID[$1]}" ;;
        *) printf 'User Slice of UID %s' "${VIRT_UID[$1]}" ;;
      esac
      return ;;
  esac
  [[ -r $DB/units/$1 ]] && d=$(sed -n 's/^Description=//p' "$DB/units/$1" 2>/dev/null | tail -n1)
  printf '%s' "${d:-$1}"
}

# --------------------------------------------------------------------------
# actions

# unit_timeout UNIT START|STOP: the unit's own limit, in milliseconds (0: none)
unit_timeout() {
  local t=
  [[ -r $DB/unit-data/$1 ]] && t=$(sed -n "s/^U_TIMEOUT_$2_MS=//p" "$DB/unit-data/$1")
  printf '%s' "${t:-0}"
}

# Start one unit directly, without s6-rc: its own processes only.
direct_start() {
  local u=$1 atom=${I_ATOM[$1]}
  if is_longrun "$u"; then
    [[ -d $SCAN/$atom ]] || { warn "$u: no service directory"; return 1; }
    [[ -d $SCAN/$atom-log ]] && s6-svc -u "$SCAN/$atom-log"
    rm -f "$STATE/$u/starts" "$STATE/$u/nrestarts"
    # Up behind s6-rc's back: during the boot, rc.init adopts what is up
    # before it switches databases, or the switch would take it away.  The
    # lock (rc.init has it while it looks and switches) keeps this from
    # falling in between; it is held only until the service is up.  (Not
    # waited for forever: a job inside an s6-rc transaction, which rc.init
    # may be waiting for with the lock, would never get it.)
    local lk=
    { exec {lk}>> /run/units/.switch-lock && flock -s -w 10 "$lk"; } 2>/dev/null || lk=
    s6-svc -uwu -T "$(unit_timeout "$u" START)" "$SCAN/$atom"
    local rc=$?
    [[ -n $lk ]] && exec {lk}>&-
    (( rc == 0 )) || return $rc
    if [[ -e $SCAN/$atom/notification-fd ]]; then
      s6-svwait -U -t "$(unit_timeout "$u" START)" "$SCAN/$atom"
    fi
  else
    local rc=0
    case ${I_KIND[$u]} in
      service) run_rt up "$DB/unit-data/$u" || rc=$? ;;
      mount) run_rt mount-up "$DB/unit-data/$u" || rc=$? ;;
      swap) run_rt swap-up "$DB/unit-data/$u" || rc=$? ;;
      socket) run_rt socket-up "$DB/unit-data/$u" || rc=$? ;;
      *) return 0 ;;
    esac
    # (the runtime lets a job nobody requires fail quietly, so that a
    # transaction goes on; asked for by hand, it is an error)
    if (( rc == 0 )); then
      unit_state "$u"
      [[ $active_state == failed ]] && rc=1
    fi
    return $rc
  fi
}

direct_stop() {
  local u=$1 atom=${I_ATOM[$1]}
  if is_longrun "$u"; then
    [[ -d $SCAN/$atom ]] || return 0
    [[ " ${I_ATOMS[$u]} " == *" $atom-hooks "* ]] && run_rt stop-hook "$DB/unit-data/$u"
    local t
    t=$(unit_timeout "$u" STOP)
    s6-svc -dwD -T "$(( t ? t + 10000 : 0 ))" "$SCAN/$atom"
    # (stopped while a restart was pending: no run is there to say so)
    if [[ -r $STATE/$u/state && $(< "$STATE/$u/state") == activating ]]; then
      printf 'inactive\n' > "$STATE/$u/state"
      printf 'success\n' > "$STATE/$u/result"
    fi
  else
    case ${I_KIND[$u]} in
      service) run_rt down "$DB/unit-data/$u" ;;
      mount) run_rt mount-down "$DB/unit-data/$u" ;;
      swap) run_rt swap-down "$DB/unit-data/$u" ;;
      socket) run_rt socket-down "$DB/unit-data/$u" ;;
      *) return 0 ;;
    esac
  fi
}

# Bring up, through s6-rc, the services of the given units that are not up
# yet, in the order their ranks give.
rc_start() {
  local u a want=() rc=0
  declare -A seen=()
  for u in "$@"; do
    for a in ${I_START[$u]}; do
      [[ -n ${seen[$a]-} ]] && continue
      seen[$a]=1
      is_rc_up "$a" || want+=("$a")
    done
  done
  (( ${#want[@]} )) || return 0
  local rank atom prev= batch=()
  declare -A wanted=()
  for a in "${want[@]}"; do wanted[$a]=1; done
  while IFS=$'\t' read -r rank atom; do
    [[ -n ${wanted[$atom]-} ]] || continue
    if [[ $rank != "$prev" && ${#batch[@]} -gt 0 ]]; then
      rc -b -u change "${batch[@]}" || rc=1
      batch=()
    fi
    prev=$rank
    batch+=("$atom")
  done < "$DB/ranks.tsv"
  if (( ${#batch[@]} )); then rc -b -u change "${batch[@]}" || rc=1; fi
  return $rc
}

# What `start`ing a target does besides what s6-rc does for it: every unit it
# wants that is not running is started, whatever s6-rc believes about it (a
# oneshot that has run, a service that failed or was stopped by hand).  It is
# how systemd ends a configuration switch, and why a failed service fails
# again at the next one.  $S6_SWITCH_SKIP: units that were just dealt with.
reactivate() {
  local t=$1 a u r list
  list=$(for a in ${I_START[$t]}; do
    u=${ATOM_UNIT[$a]-}
    [[ -n $u ]] || continue
    case ${I_KIND[$u]} in service|mount|swap|socket) printf '%s %s\n' "${I_RANK[$u]}" "$u" ;; esac
  done | sort -n | uniq)
  local rc=0
  while read -r r u; do
    [[ -n $u ]] || continue
    [[ " ${S6_SWITCH_SKIP-} " == *" $u "* ]] && continue
    unit_state "$u"
    case $active_state in
      active|activating) continue ;;
    esac
    direct_start "$u" || { warn "Failed to start $u"; rc=1; }
  done <<< "$list"
  return $rc
}

do_start() {
  local u rc=0 list=()
  for u in "$@"; do
    if resolve "$u"; then list+=("$unit"); else warn "Unit $unit not found."; rc=5; fi
  done
  (( ${#list[@]} )) || return $rc
  load_rc
  if (( rc_busy )); then
    # A target is only brought up through s6-rc, which is busy with the boot:
    # the request is queued behind it, as systemd would.
    local target=0 i
    for u in "${list[@]}"; do [[ ${I_KIND[$u]} == target ]] && target=1; done
    if (( target )); then
      for (( i = 0; i < 1200; i++ )); do
        sleep 0.1
        load_rc
        (( rc_busy )) || break
      done
    fi
  fi
  if (( rc_busy )); then
    # s6-rc is busy with another transaction; we cannot nest into it.
    for u in "${list[@]}"; do direct_start "$u" || rc=1; done
    return $rc
  fi
  rc_start "${list[@]}" || rc=1
  load_rc
  for u in "${list[@]}"; do
    if [[ ${I_KIND[$u]} == target ]]; then
      reactivate "$u" || rc=1
      continue
    fi
    unit_state "$u"
    case $active_state in
      active|activating) ;;
      *)
        # s6-rc has it as up, but it was stopped by hand, has failed, or is a
        # job that has run to completion: run it again.
        [[ ${I_KIND[$u]} == target || ${I_KIND[$u]} == device ]] || direct_start "$u" || rc=1 ;;
    esac
  done
  return $rc
}

# Units that are part of $1 (PartOf=, BindsTo=), at any depth; sets `members`.
collect_members() {
  local todo=("$1") t m name list seen=" $1 "
  members=()
  [[ -r $DB/partof.tsv ]] || return 0
  while (( ${#todo[@]} )); do
    t=${todo[0]}
    todo=("${todo[@]:1}")
    while IFS=$'\t' read -r name list; do
      [[ $name == "$t" ]] || continue
      for m in $list; do
        [[ $seen == *" $m "* ]] && continue
        seen+="$m "
        members+=("$m")
        todo+=("$m")
      done
    done < "$DB/partof.tsv"
  done
}

do_stop() {
  local u rc=0 m
  for u in "$@"; do
    if ! resolve "$u"; then warn "Unit $unit not loaded."; rc=5; continue; fi
    local name=$unit
    collect_members "$name"
    # what is part of the unit goes first, as it would under systemd
    for m in ${members[@]+"${members[@]}"}; do
      load_rc
      unit_state "$m"
      [[ $active_state == active || $active_state == activating ]] && direct_stop "$m"
    done
    direct_stop "$name" || rc=1
  done
  return $rc
}

# Is this process one of the unit's own, in its control group?
in_unit_cgroup() {
  local atom=${I_ATOM[$1]-} cg
  [[ -n $atom && -r /proc/self/cgroup ]] || return 1
  while IFS= read -r cg; do
    cg=${cg#*::}
    [[ $cg == "/units/$atom" || $cg == "/units/$atom/"* ]] && return 0
  done < /proc/self/cgroup
  return 1
}

do_restart() {
  local u rc=0 only_if_active=$1
  shift
  for u in "$@"; do
    if ! resolve "$u"; then warn "Unit $unit not found."; rc=5; continue; fi
    load_rc
    unit_state "$unit"
    if (( only_if_active )) && [[ $active_state != active && $active_state != activating ]]; then
      continue
    fi
    if [[ ${I_KIND[$unit]} == service ]] && (( ! opt_user )) && in_unit_cgroup "$unit"; then
      # Asked by the unit's own processes (the ExecStartPost= of influxdb2,
      # say): what restarts it would be killed half way.  systemd queues the
      # restart behind the job that is running; so does this: the request is
      # a file that the runtime acts on, when the start is done (it is still
      # being started) or at once (it is running).
      : > "$STATE/$unit/restart-requested"
      [[ $active_state == active ]] && s6-svc -t "$SCAN/${I_ATOM[$unit]}"
      continue
    fi
    if [[ ${I_KIND[$unit]} == target ]]; then
      do_start "$unit" || rc=1
      continue
    fi
    direct_stop "$unit"
    if (( rc_busy == 0 )) && ! is_rc_up "${I_ATOM[$unit]}"; then
      do_start "$unit" || rc=1
    else
      direct_start "$unit" || rc=1
    fi
  done
  return $rc
}

do_reload() {
  local u rc=0 fallback=$1
  shift
  for u in "$@"; do
    if ! resolve "$u"; then warn "Unit $unit not found."; rc=5; continue; fi
    if [[ ${I_KIND[$unit]} == service ]] && grep -Eq "^(U_N_RELOAD=[1-9]|U_RELOAD_SIGNAL='[A-Z])" "$DB/unit-data/$unit" 2>/dev/null; then
      run_rt reload "$DB/unit-data/$unit" || rc=1
    elif (( fallback )); then
      do_restart 0 "$unit" || rc=1
    else
      warn "Failed to reload $unit: Job type reload is not applicable for unit $unit."
      rc=1
    fi
  done
  return $rc
}

show_status() {
  local u=$1
  unit_state "$u"
  local pid mark="●" since=
  pid=$(main_pid "$u")
  [[ -r $STATE/$u/since ]] && since=$(date -d "@$(< "$STATE/$u/since")" '+%a %Y-%m-%d %H:%M:%S %Z' 2>/dev/null)
  [[ $active_state == inactive ]] && mark="○"
  [[ $active_state == failed ]] && mark="×"
  echo "$mark $u - $(description "$u")"
  echo "     Loaded: loaded ($DB/units/$u; $([[ ${I_BOOT[$u]} == 1 ]] && echo enabled || echo static))"
  echo "     Active: $active_state ($sub_state)${since:+ since $since}"
  [[ -n $pid ]] && echo "   Main PID: $pid ($(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-60))"
  echo "     s6-rc: ${I_ATOMS[$u]}"
  if [[ -r /sys/fs/cgroup/units/${I_ATOM[$u]}/cgroup.procs ]]; then
    local procs
    procs=$(tr '\n' ' ' < "/sys/fs/cgroup/units/${I_ATOM[$u]}/cgroup.procs")
    [[ -n $procs ]] && echo "     CGroup: /units/${I_ATOM[$u]} ($procs)"
  fi
  if [[ $opt_lines != 0 && -r $LOGDIR/${I_ATOM[$u]}/current ]]; then
    echo
    tail -n "$opt_lines" "$LOGDIR/${I_ATOM[$u]}/current"
  fi
  case $active_state in
    active|activating) return 0 ;;
    *) return 3 ;;
  esac
}

# The value of a setting of the unit file, for what `show` has no property of
# its own for (all the lines of the key, joined by spaces).
unit_file_value() {
  local f=$DB/units/$1
  [[ -r $f ]] || return 0
  sed -n "s/^$2=//p" "$f" | paste -sd' ' -
}

# Environment= of the unit file as `show` gives it: the assignments one after
# another, the quotes of the file taken off.
unit_environment() {
  local f=$DB/units/$1 line rest out=() re='^[[:space:]]*("([^"]*)"|([^[:space:]]+))(.*)$'
  [[ -r $f ]] || return 0
  while IFS= read -r line; do
    [[ $line == Environment=* ]] || continue
    rest=${line#Environment=}
    while [[ $rest =~ $re ]]; do
      out+=("${BASH_REMATCH[2]:-${BASH_REMATCH[3]}}")
      rest=${BASH_REMATCH[4]}
    done
  done < "$f"
  local IFS=' '
  echo "${out[*]-}"
}

do_show() {
  local u=$1 pid
  unit_state "$u"
  pid=$(main_pid "$u")
  local nrestarts=0 exit_status=0
  [[ -r $STATE/$u/nrestarts ]] && nrestarts=$(< "$STATE/$u/nrestarts")
  if [[ -r $STATE/$u/exit ]]; then
    # "CODE SIGNUM RESULT": CODE is 256 for death by a signal
    local c sg r
    read -r c sg r < "$STATE/$u/exit"
    [[ $c == 256 ]] && exit_status=$sg || exit_status=$c
  fi
  local since_ts=
  [[ -r $STATE/$u/since ]] && since_ts=$(date -d "@$(< "$STATE/$u/since")" '+%a %Y-%m-%d %H:%M:%S %Z' 2>/dev/null)
  local -A P=(
    [Id]=$u [Names]=$u [Description]=$(description "$u")
    [LoadState]=loaded [ActiveState]=$active_state [SubState]=$sub_state
    [MainPID]=${pid:-0} [UnitFileState]=$([[ ${I_BOOT[$u]} == 1 ]] && echo enabled || echo static)
    [Type]=${I_TYPE[$u]} [FragmentPath]=$DB/units/$u
    [Result]=$([[ -r $STATE/$u/result ]] && cat "$STATE/$u/result" || echo success)
    [NRestarts]=$nrestarts [ControlGroup]=/units/${I_ATOM[$u]}
    [ExecMainPID]=${pid:-0} [CanStart]=yes [CanStop]=yes
    [ExecMainStatus]=$exit_status
  )
  if [[ $active_state == active ]]; then
    P[ActiveEnterTimestamp]=$since_ts
  else
    P[InactiveEnterTimestamp]=$since_ts
  fi
  if [[ ${I_KIND[$u]} == timer ]]; then
    # when it last went off: the stamp unit-timer touches (kept over reboots,
    # so the monotonic time is 0 for what happened before this boot)
    local stamp=/var/lib/units/timers/$u mt bt last_real= last_mono=0
    if [[ -e $stamp ]]; then
      mt=$(stat -c %Y "$stamp")
      bt=$(awk '/^btime/ { print $2 }' /proc/stat)
      last_real=$(date -d "@$mt" '+%a %Y-%m-%d %H:%M:%S %Z')
      (( mt >= bt )) && last_mono=$(( (mt - bt) * 1000000 ))
    fi
    P[LastTriggerUSec]=$last_real
    P[LastTriggerUSecMonotonic]=$last_mono
  fi
  local k
  if (( ${#opt_props[@]} )); then
    for k in "${opt_props[@]}"; do
      local v=${P[$k]-}
      if [[ $k == Environment ]]; then
        v=$(unit_environment "$u")
      elif [[ -z $v && -z ${P[$k]+set} ]]; then
        v=$(unit_file_value "$u" "$k")
      fi
      if (( opt_value )); then echo "$v"; else echo "$k=$v"; fi
    done
  else
    for k in $(printf '%s\n' "${!P[@]}" | sort); do echo "$k=${P[$k]}"; done
  fi
}

list_units() {
  load_index
  load_rc
  local u
  (( opt_no_legend )) || printf '%-44s %-7s %-10s %-10s %s\n' UNIT LOAD ACTIVE SUB DESCRIPTION
  for u in $(printf '%s\n' "${!I_KIND[@]}" | sort); do
    [[ -n $opt_type && ${I_KIND[$u]} != "$opt_type" ]] && continue
    unit_state "$u"
    (( opt_failed )) && [[ $active_state != failed ]] && continue
    [[ -n $opt_state && $active_state != "$opt_state" && $sub_state != "$opt_state" ]] && continue
    if (( ! opt_all && ! opt_failed )) && [[ -z $opt_state && $active_state == inactive ]]; then continue; fi
    printf '%-44s %-7s %-10s %-10s %s\n' "$u" loaded "$active_state" "$sub_state" "$(description "$u")"
  done
}

power() {
  # halt | poweroff | reboot
  local flag
  case $1 in halt) flag=-h ;; poweroff) flag=-p ;; reboot) flag=-r ;; esac
  if (( opt_force >= 2 )); then
    exec s6-linux-init-hpr -f "$flag"
  fi
  exec s6-linux-init-hpr "$flag"
}

need_units() { (( ${#units[@]} )) || die "$verb: missing unit name"; }

# --no-block: the request is made, and not waited for (a job that is queued
# is all it is under systemd; here the same command runs on its own, out of
# the way of whoever asked, and out of the control group they are in).
detach() {
  local extra=()
  (( opt_user )) && extra+=(--user)
  # (moved out of the control group here, before returning: the caller may be
  # the last process of its unit, whose control group is emptied when it is
  # done - acme's ExecStartPost= reloading nginx was killed on the way)
  (
    setsid "$BASH" -c 'exec "$@"' _ \
      "$0" ${extra[@]+"${extra[@]}"} "$verb" "${units[@]}" > /dev/null 2>&1 &
    echo "$!" > /sys/fs/cgroup/cgroup.procs 2>/dev/null
  )
}

if (( opt_user )) && [[ ! -e $LIVE/compiled ]]; then
  # no manager for this user (not in a session, or user services are off)
  case $verb in
    is-active|is-failed|status) exit 3 ;;
    # (whether a unit is enabled is a matter of its files, as with systemd:
    # answered from the system's database of user units, below)
    is-enabled) ;;
    daemon-reload|reset-failed|import-environment|set-environment|unset-environment|show-environment) exit 0 ;;
    *) die "Failed to connect to bus: no service manager is running for this user" ;;
  esac
fi

case $verb in
  help)
    cat <<'EOF'
systemctl [OPTIONS…] COMMAND [UNIT…]

Front-end to s6-rc for systemd-style units.

  start, stop, restart, try-restart, reload, reload-or-restart, kill
  status, show, cat, is-active, is-failed, is-enabled, is-system-running
  list-units, list-unit-files, list-timers, reset-failed
  poweroff, reboot, halt, suspend
  daemon-reload                  (nothing to do: the database is compiled)

Native tools: s6-rc -a list, s6-rc-db, s6-svstat /run/service/NAME,
logs in /var/log/s6/NAME/current.
EOF
    ;;
  start)
    need_units
    (( opt_no_block )) && { detach; exit 0; }
    do_start "${units[@]}"
    rc=$?
    # --wait: until what was started has finished, and as it did
    if (( opt_wait )); then
      for u in "${units[@]}"; do
        resolve "$u" || continue
        [[ ${I_KIND[$unit]} == service ]] || continue
        switching=0
        while :; do
          # (while the boot ends in a switch of databases, the supervisors are
          # not there to ask for a moment: that is not the end of the unit)
          if [[ -e /run/units/.switching ]] && (( switching++ < 150 )); then sleep 0.2; continue; fi
          unit_state "$unit"
          [[ $active_state == active || $active_state == activating || $active_state == deactivating ]] || break
          # (an oneshot that stays: nothing to wait for)
          [[ $sub_state == exited ]] && break
          sleep 0.2
        done
        [[ $active_state == failed ]] && rc=1
      done
    fi
    exit $rc ;;
  stop) need_units
    (( opt_no_block )) && { detach; exit 0; }
    do_stop "${units[@]}" ;;
  restart) need_units
    (( opt_no_block )) && { detach; exit 0; }
    do_restart 0 "${units[@]}" ;;
  try-restart|condrestart) need_units
    (( opt_no_block )) && { detach; exit 0; }
    do_restart 1 "${units[@]}" ;;
  reload) need_units
    (( opt_no_block )) && { detach; exit 0; }
    do_reload 0 "${units[@]}" ;;
  reload-or-restart|force-reload) need_units
    (( opt_no_block )) && { detach; exit 0; }
    do_reload 1 "${units[@]}" ;;
  try-reload-or-restart)
    need_units
    (( opt_no_block )) && { detach; exit 0; }
    rc=0
    for u in "${units[@]}"; do
      resolve "$u" || continue
      load_rc; unit_state "$unit"
      [[ $active_state == active ]] && { do_reload 1 "$unit" || rc=1; }
    done
    exit $rc ;;
  isolate) need_units; do_start "${units[@]}" ;;
  kill)
    need_units
    rc=0
    for u in "${units[@]}"; do
      resolve "$u" || { rc=5; continue; }
      procs=/sys/fs/cgroup/units/${I_ATOM[$unit]}/cgroup.procs
      if [[ -r $procs ]]; then
        for pid in $(< "$procs"); do kill -s "${opt_signal#SIG}" "$pid" 2>/dev/null; done
      else
        pid=$(main_pid "$unit")
        [[ -n $pid ]] && kill -s "${opt_signal#SIG}" "$pid"
      fi
    done
    exit $rc ;;
  status)
    load_index; load_rc
    if (( ${#units[@]} == 0 )); then
      failed=0
      for u in "${!I_KIND[@]}"; do unit_state "$u"; [[ $active_state == failed ]] && failed=$(( failed + 1 )); done
      echo "● $(< /proc/sys/kernel/hostname)"
      echo "    State: $( { (( rc_busy )) || [[ -e $STATE/.booting ]]; } && echo starting || { (( failed )) && echo degraded || echo running; })"
      echo "    Units: ${#I_KIND[@]} loaded, $failed failed"
      echo "     Init: s6-linux-init / s6-rc ($DB)"
      exit 0
    fi
    rc=0
    for u in "${units[@]}"; do
      if resolve "$u"; then show_status "$unit" || rc=$?; else echo "Unit $unit could not be found." >&2; rc=4; fi
    done
    exit $rc ;;
  is-active)
    need_units; load_index; load_rc
    rc=3
    for u in "${units[@]}"; do
      if resolve "$u"; then unit_state "$unit"; else active_state=inactive; fi
      (( opt_quiet )) || echo "$active_state"
      [[ $active_state == active ]] && rc=0
    done
    exit $rc ;;
  is-failed)
    need_units; load_index; load_rc
    rc=1
    for u in "${units[@]}"; do
      if resolve "$u"; then unit_state "$unit"; else active_state=inactive; fi
      (( opt_quiet )) || echo "$active_state"
      [[ $active_state == failed ]] && rc=0
    done
    exit $rc ;;
  is-enabled)
    need_units
    rc=1
    for u in "${units[@]}"; do
      if resolve "$u"; then
        if [[ ${I_BOOT[$unit]} == 1 ]]; then st=enabled; rc=0; else st=static; rc=0; fi
      else
        st=not-found
      fi
      (( opt_quiet )) || echo "$st"
    done
    exit $rc ;;
  is-system-running)
    load_index; load_rc
    if (( rc_busy )) || [[ -e $STATE/.booting ]]; then st=starting; rc=1
    else
      st=running; rc=0
      for u in "${!I_KIND[@]}"; do unit_state "$u"; [[ $active_state == failed ]] && { st=degraded; rc=1; break; }; done
    fi
    (( opt_quiet )) || echo "$st"
    exit $rc ;;
  show)
    load_index; load_rc
    if (( ${#units[@]} == 0 )); then
      echo "Version=s6-rc"
      echo "SystemState=$( (( rc_busy )) && echo starting || echo running)"
      exit 0
    fi
    for u in "${units[@]}"; do
      if resolve "$u"; then do_show "$unit"; else
        if (( ${#opt_props[@]} )); then
          for k in "${opt_props[@]}"; do
            case $k in LoadState) v=not-found ;; ActiveState) v=inactive ;; SubState) v=dead ;; MainPID) v=0 ;; *) v= ;; esac
            if (( opt_value )); then echo "$v"; else echo "$k=$v"; fi
          done
        else
          echo "Id=$unit"; echo "LoadState=not-found"; echo "ActiveState=inactive"
        fi
      fi
    done ;;
  cat)
    need_units
    for u in "${units[@]}"; do
      resolve "$u" || die "No files found for $unit."
      echo "# $DB/units/$unit"
      cat "$DB/units/$unit" 2>/dev/null
      for f in "$DB/units/$unit.d"/*.conf; do [[ -r $f ]] && { echo; echo "# $f"; cat "$f"; }; done
    done ;;
  list-units) list_units ;;
  list-unit-files)
    load_index
    (( opt_no_legend )) || printf '%-44s %s\n' "UNIT FILE" STATE
    for u in $(printf '%s\n' "${!I_KIND[@]}" | sort); do
      [[ -n $opt_type && ${I_KIND[$u]} != "$opt_type" ]] && continue
      printf '%-44s %s\n' "$u" "$([[ ${I_BOOT[$u]} == 1 ]] && echo enabled || echo static)"
    done ;;
  list-timers)
    load_index; load_rc
    (( opt_no_legend )) || printf '%-36s %-10s %s\n' UNIT ACTIVE LAST
    for u in $(printf '%s\n' "${!I_KIND[@]}" | sort); do
      [[ ${I_KIND[$u]} == timer ]] || continue
      unit_state "$u"
      last=-
      [[ -e /var/lib/units/timers/$u ]] && last=$(date -r "/var/lib/units/timers/$u" '+%Y-%m-%d %H:%M:%S')
      printf '%-36s %-10s %s\n' "$u" "$active_state" "$last"
    done ;;
  list-jobs)
    # There is no job queue to look at; what can be said is whether a
    # transaction is in progress.
    load_rc
    if (( rc_busy )) || [[ -e $STATE/.booting ]]; then
      (( opt_no_legend )) || echo "JOB UNIT                 TYPE  STATE"
      echo "  1 default.target       start running"
      (( opt_no_legend )) || { echo; echo "1 jobs listed."; }
    else
      echo "No jobs running."
    fi ;;
  list-dependencies|list-sockets|list-machines) die "$verb is not implemented" ;;
  reset-failed)
    load_index
    if (( ${#units[@]} )); then
      for u in "${units[@]}"; do resolve "$u" && rm -f "$STATE/$unit/state" "$STATE/$unit/result" "$STATE/$unit/starts"; done
    else
      for u in "${!I_KIND[@]}"; do
        [[ -r $STATE/$u/state && $(< "$STATE/$u/state") == failed ]] && rm -f "$STATE/$u/state" "$STATE/$u/result" "$STATE/$u/starts"
      done
    fi
    exit 0 ;;
  daemon-reload|daemon-reexec|log-level|service-watchdogs)
    exit 0 ;;
  import-environment)
    # the activation environment: what services started from now on see in
    # addition to the manager's own
    mkdir -p "$STATE/.env"
    if (( ${#units[@]} )); then names=("${units[@]}"); else mapfile -t names < <(compgen -e); fi
    for n in "${names[@]}"; do
      [[ $n =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
      [[ ${!n+set} ]] && printf '%s' "${!n}" > "$STATE/.env/$n"
    done
    exit 0 ;;
  set-environment)
    mkdir -p "$STATE/.env"
    for a in "${units[@]}"; do
      n=${a%%=*}
      [[ $n =~ ^[A-Za-z_][A-Za-z0-9_]*$ && $a == *=* ]] && printf '%s' "${a#*=}" > "$STATE/.env/$n"
    done
    exit 0 ;;
  unset-environment)
    for n in "${units[@]}"; do rm -f "$STATE/.env/${n%%=*}"; done
    exit 0 ;;
  show-environment)
    env
    if [[ -d $STATE/.env ]]; then
      set +f
      for f in "$STATE"/.env/*; do
        [[ -f $f ]] && printf '%s=%s\n' "${f##*/}" "$(< "$f")"
      done
    fi ;;
  enable|disable|reenable|preset|preset-all|mask|unmask|link|revert|edit|set-default|add-wants|add-requires)
    warn "'$verb' does nothing here: which units are enabled is part of the system configuration."
    if [[ $verb == enable ]] && (( opt_now )); then need_units; do_start "${units[@]}"; fi
    if [[ $verb == disable ]] && (( opt_now )); then need_units; do_stop "${units[@]}"; fi
    exit 0 ;;
  get-default) load_index; echo "${ALIAS[default.target]-multi-user.target}" ;;
  poweroff|halt|reboot) power "$verb" ;;
  kexec) exec s6-linux-init-hpr -r ;;
  suspend|hibernate|hybrid-sleep|suspend-then-hibernate)
    if command -v loginctl > /dev/null 2>&1; then exec loginctl "$verb"; fi
    case $verb in
      suspend) echo mem > /sys/power/state ;;
      hibernate) echo disk > /sys/power/state ;;
      *) die "$verb needs a login manager" ;;
    esac ;;
  rescue|emergency|default) die "$verb is not implemented" ;;
  *) die "Unknown command verb '$verb'." ;;
esac
