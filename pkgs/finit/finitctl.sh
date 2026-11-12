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
# The status of every stanza, as JSON.  initctl asks Finit for one stanza
# after the other, through one iterator in PID 1 that all clients share:
# two walks at a time take stanzas from each other.  Ours take turns (the
# lock), and a snapshot with fewer stanzas than the database has atoms (a
# walk of someone else's in between) is taken again.
snapshot() {
  local i data atoms
  atoms=$(wc -l < /run/units/.db/finit-names.tsv)
  for (( i = 0; i < 20; i++ )); do
    data=$(flock /run/finitctl.lock "$ctl" -j status 2>/dev/null) &&
      jq -e --argjson n "$atoms" 'type == "array" and length >= $n' <<< "$data" > /dev/null 2>&1 &&
      { printf '%s\n' "$data"; return 0; }
    sleep 0.05
  done
  echo "finitctl: Finit does not answer" >&2
  return 1
}
lookup() {
  local atom native
  while IFS=$'\t' read -r atom native; do
    [[ $atom == "$1" ]] && { echo "$native"; return 0; }
  done < /run/units/.db/finit-names.tsv
  return 1
}
# how the last run of each task ended (the run scripts of unitc's
# emit_finit write it): Finit does not keep it for a task started by hand
results=/run/units/.finit-rc
# Finit acknowledges IPC requests before the service transition finishes.
# Bound synchronous calls; callers doing batches can explicitly use --no-wait.
# A task is up once its run has ended and noted a success.
wait_state() {
  local goal=$1 state type deadline=$((SECONDS + 90))
  while (( SECONDS < deadline )); do
    state=$("$ctl" -j status "$native") || return $?
    type=$(jq -r '.type' <<< "$state") || return $?
    state=$(jq -r '.status' <<< "$state") || return $?
    if [[ $goal == up && $type == task ]]; then
      if [[ $state != @(running|active|waiting|starting|setup) && -r $results/$native && $(< "$results/$native") != - ]]; then
        [[ $(< "$results/$native") == 0 ]] && return 0
        echo "finitctl: $native failed" >&2
        return 1
      fi
      sleep 0.1
      continue
    fi
    case $goal:$state in
      up:running)
        # The process exists before notify:s6 reports readiness.
        "$ctl" cond get "service/$native/ready" && return 0
        ;;
      up:done|down:stopped|down:halted|down:done) return 0 ;;
      up:failed|up:crashed|up:missing|up:dead|up:conflict)
        echo "finitctl: $native did not come up ($state)" >&2
        return 1 ;;
    esac
    sleep 0.1
  done
  echo "finitctl: timed out waiting for $native to become $goal" >&2
  return 1
}
case $cmd in
  list)
    data=$(snapshot) || exit $?
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
        failed|crashed|missing|conflict|dead) printf '[     {X}] %s\n' "$atom" ;;
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
    # What an atom requires and wants is started with it, and what requires
    # it is stopped with it (and started again after a restart), as dinit
    # does; finit-deps.tsv has the edges (unitc's emit_finit).
    declare -A hard=() wants=() native_of=() status=() seen=()
    # (fields split by hand: read would take two tabs in a row - an atom
    # that requires nothing - for one)
    while IFS= read -r line; do
      atom=${line%%$'\t'*} line=${line#*$'\t'}
      hard[$atom]=${line%%$'\t'*} wants[$atom]=${line#*$'\t'}
    done < /run/units/.db/finit-deps.tsv
    while IFS=$'\t' read -r atom n; do native_of[$atom]=$n; done < /run/units/.db/finit-names.tsv
    # The status of every stanza for a stop or restart (what requires the
    # atom is looked for among all of them).  A start asks about the atoms
    # it comes across, one at a time: those that are up are not looked
    # into, so that is a few, and a start is what a socket's first client
    # waits for.
    if [[ $cmd != start ]]; then
      data=$(snapshot) || exit $?
      while IFS=$'\t' read -r n st; do [[ -n $n ]] && status[$n]=$st; done \
        < <(jq -r '.[] | [.identity, .status] | @tsv' <<< "$data")
    fi
    # (STATUS: what Finit says of ATOM; no subshell, so that it is asked once)
    fetch() {
      local n=${native_of[$1]-}
      [[ -n $n ]] || { STATUS=; return; }
      [[ -n ${status[$n]+set} ]] ||
        status[$n]=$("$ctl" -j status "$n" 2>/dev/null | jq -r '.status // empty' 2>/dev/null)
      STATUS=${status[$n]}
    }
    # (what is up or on its way: running, done, waiting for its conditions)
    is_on() { fetch "$1"; [[ $STATUS == @(running|done|waiting|starting|setup) ]]; }
    start_deps() {
      local dep
      for dep in ${hard[$1]-} ${wants[$1]-}; do
        [[ -n ${seen[$dep]-} ]] && continue
        seen[$dep]=1
        # (one that is up has what it needs up already)
        is_on "$dep" && continue
        start_deps "$dep"
        "$ctl" start "${native_of[$dep]}" >/dev/null
      done
    }
    # the atoms that require $1 and are on, those furthest from it first
    dependents() {
      local atom
      for atom in "${!hard[@]}"; do
        [[ " ${hard[$atom]} " == *" $1 "* && -z ${seen[$atom]-} ]] || continue
        seen[$atom]=1
        is_on "$atom" || continue
        dependents "$atom"
        echo "$atom"
      done
    }
    # Stop ATOM.  Finit has nothing to run for a task that is stopped: its
    # stop command (socket-down, mount-down, ExecStop= of a oneshot that
    # remains) is run here, if the task had run.
    stop_one() {
      local native=${native_of[$1]} was stop=/run/units/.db/finit/stop-${native_of[$1]}
      fetch "$1"; was=$STATUS
      "$ctl" stop "$native" || return $?
      if [[ -x $stop && $was == @(done|running|active) ]]; then
        "$stop" || true
      fi
      (( nowait )) || wait_state down
    }
    down=()
    if [[ $cmd != start ]]; then
      mapfile -t down < <(dependents "$name")
      for dep in ${down[@]+"${down[@]}"}; do stop_one "$dep" || exit $?; done
      stop_one "$name" || exit $?
    fi
    [[ $cmd == stop ]] && exit 0
    seen=([$name]=1)
    start_deps "$name"
    # (a task done already stays so, as a started service stays started;
    # one to run has the note of its last run removed, to wait for the next)
    fetch "$name"
    if [[ $cmd == start && $STATUS == done ]]; then exit 0; fi
    # (Finit drops a start that comes while the stanza is being stopped -
    # a socket's next client right after `systemctl stop`: the stop is
    # waited for first)
    for (( i = 0; i < 300; i++ )); do
      st=$("$ctl" -j status "$native" | jq -r .status) || break
      [[ $st == @(stopping|teardown|cleanup) ]] || break
      sleep 0.1
    done
    rm -f "$results/$native"
    "$ctl" start "$native" || exit $?
    rc=0
    (( nowait )) || wait_state up || rc=$?
    # (what the restart took down comes back, nearest last)
    for (( i = ${#down[@]} - 1; i >= 0; i-- )); do
      "$ctl" start "${native_of[${down[i]}]}" >/dev/null || rc=1
    done
    exit $rc
    ;;
  # Finit reads every description again on rescan; one service is not
  # loaded or unloaded on its own.
  reload|unload) exit 0 ;;
  rescan)
    # Finit re-reads its configuration (finit.conf includes the services of
    # the database /run/units/.db points to): what is gone is stopped, what
    # is new is started, what runs another command line is restarted.  The
    # request is answered before that happens: wait until no service is in
    # the middle of a transition (paused ones wait for their conditions to
    # be asserted again).
    "$ctl" reload || exit $?
    deadline=$((SECONDS + 90))
    sleep 0.2
    while (( SECONDS < deadline )); do
      data=$(snapshot) || exit $?
      busy=$(jq -r '[.[] | select(.status | test("^(stopping|paused|starting|setup|cleanup|teardown|busy|restart)$"))] | length' <<< "$data") || exit $?
      (( busy == 0 )) && exit 0
      sleep 0.2
    done
    echo "finitctl: timed out waiting for the configuration to be read again; still busy:" >&2
    jq -r '.[] | select(.status | test("^(stopping|paused|starting|setup|cleanup|teardown|busy|restart)$")) | "  " + .identity + " " + .status + " " + .command' <<< "$data" >&2
    exit 1
    ;;
  *) echo "finitctl: unsupported command $cmd" >&2; exit 1 ;;
esac
