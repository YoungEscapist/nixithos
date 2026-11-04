#!@shell@
# switch-to-configuration - make a built system the one that runs.
#
#   switch-to-configuration switch|boot|test|dry-activate|plan
#
# Same contract as the NixOS program of that name (it is what nixos-rebuild
# calls): `boot` only updates the boot loader, `test` only changes the
# running system, `switch` does both, `dry-activate` says what would happen.
# `plan` (not in NixOS) says which units would be stopped, restarted, reloaded
# or started and why, as lines of tab-separated fields, for `nixith diff`;
# it changes nothing and takes no lock.
#
# Changing the running system means:
#   1. stop the units whose definition changed and that want to be stopped
#      before their configuration is replaced (the default, `stopIfChanged`);
#   2. run the activation script (/etc, users, …);
#   3. hand the new service database to s6-rc-update, which stops what no
#      longer exists and restarts what we tell it has changed;
#   4. start what is new, reload what asked to be reloaded.
# Units that did not change are not touched.
#
# Under dinit, 3. is: /run/units/.db is pointed at the new database (the
# services refer to everything through it), the services dinit has loaded
# whose descriptions changed are read again (dinitctl reload), those that
# are gone are unloaded, and what changed is restarted.  A configuration for
# the other init system than the one that runs is only activated: its
# services take over at the next boot.

PATH=@path@:$PATH
RUNTIME=@runtime@
set -u

toplevel=${TOPLEVEL:?switch-to-configuration must be run through the system closure}
action=${1-}

case $action in
  switch|boot|test|dry-activate|plan) ;;
  *)
    cat >&2 <<EOF
Usage: $0 [switch|boot|test|dry-activate|plan]

switch:       make the configuration the boot default and activate now
boot:         make the configuration the boot default
test:         activate the configuration, but don't make it the boot default
dry-activate: show what would be done if this configuration were activated
plan:         the same for the units, as TAB separated lines (action, unit, why)
EOF
    exit 1 ;;
esac

STATE=/run/units
SCAN=/run/service

if [[ $action != plan ]]; then
  mkdir -p /run/nixos
  exec 9> /run/nixos/switch-to-configuration.lock
  flock 9 || { echo "could not acquire the switch lock" >&2; exit 1; }
fi

if [[ $action != plan && -z ${NIXOS_NO_CHECK-} && -n ${PRE_SWITCH_CHECK-} ]]; then
  "$PRE_SWITCH_CHECK" "$toplevel" "$action" || exit $?
fi

if [[ $action == switch || $action == boot ]]; then
  chmod u+w /nix/var/nix/gcroots 2>/dev/null
  if ! "${INSTALL_BOOTLOADER:?}" "$toplevel"; then
    echo "warning: installing the boot loader failed" >&2
    exit 1
  fi
  sync
fi
[[ $action == boot ]] && exit 0

new_db=$(readlink -f "$toplevel/s6-db")

# the init system that runs, and the one of the new configuration.  runit
# goes as dinit does: its services are described the same way (in runit/ in
# place of dinit/), and unit-rc answers to what dinitctl is asked here;
# *_kind tells them apart.
running_init=s6 running_kind=s6
if [[ -L $STATE/.db && ! -e /run/s6-rc/compiled ]]; then
  running_init=dinit running_kind=dinit
  [[ -d $STATE/.db/runit ]] && running_kind=runit
fi
new_init=s6 new_kind=s6
[[ -d $new_db/dinit ]] && new_init=dinit new_kind=dinit
[[ -d $new_db/runit ]] && new_init=dinit new_kind=runit
# (a command to dinit that does not come back - a service that never gets to
# where it is going - is a warning, not a switch that hangs for good)
DINITCTL=(timeout 300 dinitctl -p /run/dinitctl)
[[ $running_kind == runit ]] && DINITCTL=(timeout 300 unit-rc -p /run/rcctl)

if [[ $running_init == dinit ]]; then
  live=$(readlink -f "$STATE/.db" 2>/dev/null) || live=
  old_db=$live
else
  live=$(readlink -f /run/s6-rc/compiled 2>/dev/null) || live=
  old_db=${live%/*}
fi

if [[ -z $live || ! -r $old_db/switch.tsv ]]; then
  # Not running on s6-rc (a chroot, an installer): there is nothing to
  # reconcile, just lay down the configuration.
  if [[ $action == plan ]]; then printf '#note\tno service manager of this system is running (a chroot, an installer): there are no units to compare\n'; exit 0; fi
  if [[ $action == dry-activate ]]; then exec "$toplevel/dry-activate" "$toplevel"; fi
  echo "activating the configuration..."
  exec "$toplevel/activate" "$toplevel"
fi

if [[ $running_kind != "$new_kind" ]]; then
  # What runs stays as it is: the new init system and its services take over
  # at the next boot.  The rest of the configuration is laid down now.
  echo "the new configuration is for $new_kind, and $running_kind runs this machine: its services change over at the next boot" >&2
  if [[ $action == plan ]]; then printf '#note\tthe new configuration is for %s and %s runs this machine: its services change over at the next boot\n' "$new_kind" "$running_kind"; exit 0; fi
  if [[ $action == dry-activate ]]; then exec "$toplevel/dry-activate" "$toplevel"; fi
  echo "activating the configuration..."
  exec "$toplevel/activate" "$toplevel"
fi

# (dinit) DN: the name dinit knows atom $1 by (see unitc's dname)
dname() {
  DN=${1//@/＠}
  DN=${DN//\\/∖}
  DN=${DN//:/꞉}
}

# (dinit) Is the process of a longrun running?  (unit-supervise's status)
sv_running() {
  local u= _ sv=
  [[ -r $STATE/.sv/$1 ]] || return 1
  read -r u _ _ _ sv _ < "$STATE/.sv/$1"
  [[ $u == 1 ]] && kill -0 "$sv" 2>/dev/null
}

# --------------------------------------------------------------------------
# what changed

declare -A OLD_HASH OLD_ATOMS NEW_HASH NEW_ATOMS NEW_RESTART NEW_RELOAD NEW_STOP
while IFS=$'\t' read -r unit hash restart reload stop atoms; do
  OLD_HASH[$unit]=$hash OLD_ATOMS[$unit]=$atoms
done < "$old_db/switch.tsv"
while IFS=$'\t' read -r unit hash restart reload stop atoms; do
  NEW_HASH[$unit]=$hash NEW_ATOMS[$unit]=$atoms
  NEW_RESTART[$unit]=$restart NEW_RELOAD[$unit]=$reload NEW_STOP[$unit]=$stop
done < "$new_db/switch.tsv"

declare -A NEW_ATOM_EXISTS NEW_RANK NEW_KIND NEW_TYPE NEW_BOOT NEW_UNIT_RANK
while IFS=$'\t' read -r rank atom; do
  NEW_ATOM_EXISTS[$atom]=1 NEW_RANK[$atom]=$rank
done < "$new_db/ranks.tsv"
while IFS=$'\t' read -r unit kind type rank boot atom atoms startset; do
  NEW_KIND[$unit]=$kind NEW_TYPE[$unit]=$type NEW_BOOT[$unit]=$boot NEW_UNIT_RANK[$unit]=$rank
done < "$new_db/index.tsv"

# A job that runs once at boot (Type=oneshot, no RemainAfterExit=) is "inactive"
# when done.  If its definition changes it is to run again, which is what
# restartTriggers on such a unit are for (nginx-config-reload, tmpfiles).
is_run_once() {
  [[ ${NEW_KIND[$1]-} == service && ${NEW_TYPE[$1]-} == oneshot && ${NEW_BOOT[$1]-0} == 1 ]] || return 1
  ! grep -q '^U_REMAIN=1' "$new_db/unit-data/$1" 2>/dev/null
}

# (another transaction may be going on, a unit starting its dependencies:
# the lock is waited for, as systemd queues a job behind the running ones)
if [[ $running_init == dinit ]]; then
  # what dinit has started ("[{+}     ] name …"), by dinit name
  listing=$("${DINITCTL[@]}" list 2>/dev/null) || { echo "dinit is not answering" >&2; exit 1; }
  up=" "
  while IFS= read -r line; do
    [[ ${line:2:1} == [+s] ]] || continue
    line=${line:11}
    up+="${line%% *} "
  done <<< "$listing"
  is_up() { dname "$1"; [[ $up == *" $DN "* ]]; }
else
  up=$(s6-rc -b -a list 2>/dev/null) || { echo "s6-rc is not answering" >&2; exit 1; }
  up=" ${up//$'\n'/ } "
  is_up() { [[ $up == *" $1 "* ]]; }
fi

# Is the unit doing something right now?  (A oneshot that has run and is
# done counts, as long as it "remains after exit".)
is_active() {
  local unit=$1 atom st=
  atom=${OLD_ATOMS[$unit]%% *}
  [[ -n $atom ]] || return 1
  is_up "$atom" || return 1
  if [[ $running_init == dinit && -r $STATE/.sv/$atom ]]; then
    sv_running "$atom"
    return
  fi
  if [[ -d $SCAN/$atom ]]; then
    [[ $(s6-svstat -o up "$SCAN/$atom" 2>/dev/null) == true ]]
    return
  fi
  [[ -r $STATE/$unit/state ]] && st=$(< "$STATE/$unit/state")
  case $unit in
    *.target|*.device) return 0 ;;
  esac
  [[ $st == active ]]
}

# Why a unit counts as changed, in a line (for the plan): the keys of its unit
# file and drop-ins that differ, with what changed in the store paths they
# name; then its runtime data, if the file is the same.
store_names() { grep -o '/nix/store/[a-z0-9]\{32\}-[^ /"'"'"':;]*' | sed 's#^/nix/store/[a-z0-9]*-##; s#^X-\(Restart\|Reload\)-Triggers-##'; }
# store paths that are in the first set of lines and not in the second, then
# the other way round, by name: "pkg-1 -> pkg-2", "added x", "rebuilt x"
store_delta() {
  local gone new g n
  gone=$(comm -23 <(printf '%s\n' "$1" | grep -o '/nix/store/[a-z0-9]\{32\}-[^ /"'"'"':;]*' | sort -u) <(printf '%s\n' "$2" | grep -o '/nix/store/[a-z0-9]\{32\}-[^ /"'"'"':;]*' | sort -u))
  new=$(comm -13 <(printf '%s\n' "$1" | grep -o '/nix/store/[a-z0-9]\{32\}-[^ /"'"'"':;]*' | sort -u) <(printf '%s\n' "$2" | grep -o '/nix/store/[a-z0-9]\{32\}-[^ /"'"'"':;]*' | sort -u))
  g=$(store_names <<< "$gone" | sort -u | head -n 3 | paste -sd, - | sed 's/,/, /g')
  n=$(store_names <<< "$new" | sort -u | head -n 3 | paste -sd, - | sed 's/,/, /g')
  if [[ -n $g && -n $n ]]; then
    if [[ $g == "$n" ]]; then printf 'rebuilt: %s' "$n"; else printf '%s -> %s' "$g" "$n"; fi
  elif [[ -n $n ]]; then printf 'added %s' "$n"
  elif [[ -n $g ]]; then printf 'removed %s' "$g"
  fi
}
unit_text() {  # the unit file and its drop-ins, the settings only
  local f=$1/units/$2
  { cat "$f" "$f".d/*.conf 2>/dev/null || true; } | grep -E '^[A-Za-z][A-Za-z0-9-]*=' | sort -u
}
why_changed() {
  local unit=$1 a b key keys parts=() o n shown=0
  a=$(unit_text "$old_db" "$unit") b=$(unit_text "$new_db" "$unit")
  keys=$(comm -3 <(printf '%s\n' "$a") <(printf '%s\n' "$b") | sed -E 's/^[[:space:]]+//; s/=.*//' | sort -u)
  for key in $keys; do
    (( shown++ >= 4 )) && { parts+=("..."); break; }
    o=$(printf '%s\n' "$a" | sed -n "s/^$key=//p")
    n=$(printf '%s\n' "$b" | sed -n "s/^$key=//p")
    case $key in
      X-Restart-Triggers|X-Reload-Triggers)
        local what=restartTriggers names
        [[ $key == X-Reload-Triggers ]] && what=reloadTriggers
        # the paths that are not in both, by name
        names=$(comm -3 <(printf '%s\n' $o | sort -u) <(printf '%s\n' $n | sort -u) | store_names | sort -u | head -n 3 | paste -sd, - | sed 's/,/, /g')
        parts+=("$what changed${names:+ ($names)}") ;;
      *)
        local d
        d=$(store_delta "$o" "$n")
        parts+=("$key changed${d:+ ($d)}") ;;
    esac
  done
  if (( ${#parts[@]} == 0 )); then
    if ! cmp -s "$old_db/unit-data/$unit" "$new_db/unit-data/$unit" 2>/dev/null; then
      parts+=("how it is run changed (paths or environment of its tools)")
    else
      parts+=("its definition changed")
    fi
  fi
  local out= part
  for part in "${parts[@]}"; do out+="${out:+; }$part"; done
  printf '%s\n' "$out"
}

removed=() stop_start=() restart=() reload=() skipped=() rerun=() idle=0 same=0
for unit in "${!OLD_HASH[@]}"; do
  if [[ -z ${NEW_HASH[$unit]-} ]]; then
    is_active "$unit" && removed+=("$unit")
    continue
  fi
  if [[ ${OLD_HASH[$unit]} == "${NEW_HASH[$unit]}" ]]; then same=$(( same + 1 )); continue; fi
  if is_run_once "$unit"; then
    rerun+=("$unit")
    continue
  fi
  is_active "$unit" || { idle=$(( idle + 1 )); continue; }
  case $unit in *.target|*.device) continue ;; esac
  if [[ ${NEW_RELOAD[$unit]} == 1 ]]; then
    reload+=("$unit")
  elif [[ ${NEW_RESTART[$unit]} != 1 ]]; then
    skipped+=("$unit")
  elif [[ ${NEW_STOP[$unit]} == 1 ]]; then
    stop_start+=("$unit")
  else
    restart+=("$unit")
  fi
done

# units that the new system starts at boot and that are not up
start=() start_atoms=()
while IFS=$'\t' read -r unit kind type rank boot atom atoms startset; do
  [[ $boot == 1 ]] || continue
  missing=0
  for a in $atoms; do
    if ! is_up "$a"; then missing=1; start_atoms+=("$a"); fi
  done
  (( missing )) && [[ $kind != target && $kind != device ]] && start+=("$unit")
done < "$new_db/index.tsv"

list() { local IFS=,; printf '%s\n' "${*}" | sed 's/,/, /g'; }
sorted() { printf '%s\n' "$@" | sort; }

if [[ $action == plan ]]; then
  # action  unit  why; then "same N" and "idle N" (changed, not running)
  plan() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }
  for unit in $(sorted ${removed[@]+"${removed[@]}"}); do plan stop "$unit" "no longer in the configuration"; done
  for unit in $(sorted ${stop_start[@]+"${stop_start[@]}"}); do
    plan stop-start "$unit" "$(why_changed "$unit")"
  done
  for unit in $(sorted ${restart[@]+"${restart[@]}"}); do plan restart "$unit" "$(why_changed "$unit")"; done
  for unit in $(sorted ${rerun[@]+"${rerun[@]}"}); do
    plan rerun "$unit" "$(why_changed "$unit")"
  done
  for unit in $(sorted ${reload[@]+"${reload[@]}"}); do plan reload "$unit" "$(why_changed "$unit")"; done
  for unit in $(sorted ${skipped[@]+"${skipped[@]}"}); do
    plan keep "$unit" "$(why_changed "$unit")"
  done
  for unit in $(sorted ${start[@]+"${start[@]}"}); do
    if [[ -z ${OLD_HASH[$unit]-} ]]; then plan start "$unit" "new unit"
    else plan start "$unit" "wanted at boot, not running now"; fi
  done
  printf 'same\t%s\t\nidle\t%s\t\n' "$same" "$idle"
  exit 0
fi

if [[ $action == dry-activate ]]; then
  (( ${#removed[@]} + ${#stop_start[@]} )) && echo "would stop the following units: $(list $(sorted "${removed[@]}" "${stop_start[@]}"))"
  (( ${#skipped[@]} )) && echo "would NOT restart the following changed units: $(list $(sorted "${skipped[@]}"))"
  "$toplevel/dry-activate" "$toplevel"
  (( ${#reload[@]} )) && echo "would reload the following units: $(list $(sorted "${reload[@]}"))"
  (( ${#restart[@]} + ${#rerun[@]} )) && echo "would restart the following units: $(list $(sorted ${restart[@]+"${restart[@]}"} ${rerun[@]+"${rerun[@]}"}))"
  (( ${#start[@]} + ${#stop_start[@]} )) && echo "would start the following units: $(list $(sorted "${start[@]}" "${stop_start[@]}"))"
  exit 0
fi

rc=0

# --------------------------------------------------------------------------
# 1. stop, with the old definitions

if (( ${#removed[@]} + ${#stop_start[@]} )); then
  echo "stopping the following units: $(list $(sorted "${removed[@]}" "${stop_start[@]}"))"
fi
if [[ $running_init == dinit ]]; then
  # (with what requires them: they come back with the targets at the end; the
  # units that are gone are stopped here too, as systemd does)
  for unit in ${stop_start[@]+"${stop_start[@]}"} ${removed[@]+"${removed[@]}"}; do
    dname "${OLD_ATOMS[$unit]%% *}"
    "${DINITCTL[@]}" --quiet stop --force --ignore-unstarted "$DN"
  done
  stop_start_s6=()
else
  stop_start_s6=(${stop_start[@]+"${stop_start[@]}"})
fi
for unit in ${stop_start_s6[@]+"${stop_start_s6[@]}"}; do
  atom=${OLD_ATOMS[$unit]%% *}
  if [[ -d $SCAN/$atom ]]; then
    [[ " ${OLD_ATOMS[$unit]} " == *" $atom-hooks "* ]] && "$RUNTIME" stop-hook "$old_db/unit-data/$unit"
    s6-svc -dwD -T 100000 "$SCAN/$atom"
  else
    case $unit in
      *.service) "$RUNTIME" down "$old_db/unit-data/$unit" ;;
      *.mount) "$RUNTIME" mount-down "$old_db/unit-data/$unit" ;;
      *.socket) "$RUNTIME" socket-down "$old_db/unit-data/$unit" ;;
      *.swap) "$RUNTIME" swap-down "$old_db/unit-data/$unit" ;;
    esac
  fi
done
(( ${#skipped[@]} )) && echo "NOT restarting the following changed units: $(list $(sorted "${skipped[@]}"))"

# --------------------------------------------------------------------------
# 2. activate

echo "activating the configuration..."
if ! "$toplevel/activate" "$toplevel"; then
  echo "warning: the activation script reported errors" >&2
  rc=2
fi

# --------------------------------------------------------------------------
# 3. new service database

conv=$(mktemp /run/nixos/s6-rc-conversion.XXXXXX)
for unit in ${stop_start[@]+"${stop_start[@]}"} ${restart[@]+"${restart[@]}"}; do
  for atom in ${OLD_ATOMS[$unit]}; do
    [[ -n ${NEW_ATOM_EXISTS[$atom]-} ]] && printf '"%s" restart\n' "$atom" >> "$conv"
  done
done

(( ${#restart[@]} + ${#rerun[@]} )) && echo "restarting the following units: $(list $(sorted ${restart[@]+"${restart[@]}"} ${rerun[@]+"${rerun[@]}"}))"
(( ${#start[@]} + ${#stop_start[@]} )) && echo "starting the following units: $(list $(sorted ${start[@]+"${start[@]}"} ${stop_start[@]+"${stop_start[@]}"}))"

if [[ $running_init == dinit ]]; then
  if [[ $new_db != "$old_db" ]]; then
    ln -sfn "$new_db" "$STATE/.db"
    ln -sfn "$new_db" /nix/var/nix/gcroots/units-live 2>/dev/null
    # (unit-rc: a runsv for each process of the new database, none for those
    # that are gone)
    [[ $running_kind == runit ]] && "${DINITCTL[@]}" --quiet rescan
    # What dinit has loaded and is described differently now is read again;
    # what is gone is unloaded once nothing refers to it any more.
    gone=()
    while IFS= read -r line; do
      line=${line:11}
      name=${line%% *}
      [[ -n $name ]] || continue
      if [[ ! -e $new_db/$running_kind/$name ]]; then gone+=("$name"); continue; fi
      cmp -s "$old_db/$running_kind/$name" "$new_db/$running_kind/$name" && continue
      if ! "${DINITCTL[@]}" --quiet reload "$name" 2>/dev/null; then
        # (a running service that cannot take the change - another kind of
        # service, a requirement that is not up - is stopped first; the
        # targets bring it back at the end)
        "${DINITCTL[@]}" --quiet stop --force --ignore-unstarted "$name"
        "${DINITCTL[@]}" --quiet reload "$name" || { echo "warning: dinit cannot read $name again" >&2; rc=4; }
      fi
    done <<< "$("${DINITCTL[@]}" list 2>/dev/null)"
    for name in ${gone[@]+"${gone[@]}"}; do
      "${DINITCTL[@]}" --quiet stop --force --ignore-unstarted "$name"
    done
    # (a service is unloaded only once what refers to it is: as many rounds
    # as it takes)
    while (( ${#gone[@]} )); do
      left=()
      for name in "${gone[@]}"; do
        "${DINITCTL[@]}" --quiet unload "$name" 2>/dev/null || left+=("$name")
      done
      (( ${#left[@]} < ${#gone[@]} )) || break
      gone=(${left[@]+"${left[@]}"})
    done
  fi
  for unit in ${restart[@]+"${restart[@]}"}; do
    dname "${NEW_ATOMS[$unit]%% *}"
    if is_up "${NEW_ATOMS[$unit]%% *}"; then
      "${DINITCTL[@]}" --quiet restart --force "$DN" || rc=4
    else
      "${DINITCTL[@]}" --quiet start "$DN" || rc=4
    fi
  done
elif [[ $new_db != "$old_db" ]]; then
  s6-rc-update -b -v1 -f "$conv" "$new_db/compiled"
  code=$?
  case $code in
    0) ;;
    1|2)
      echo "warning: some services did not come back after the database switch" >&2
      rc=4 ;;
    *)
      echo "error: s6-rc-update failed with status $code; the service database was NOT switched." >&2
      echo "The running services still follow the previous configuration; reboot to get to the new one." >&2
      rm -f "$conv"
      exit 4 ;;
  esac
  ln -sfn "$new_db" /nix/var/nix/gcroots/s6-rc-live 2>/dev/null
fi
rm -f "$conv"

# --------------------------------------------------------------------------
# 4. start what is new (in the order ranks give), reload what asked for it

if [[ $running_init == dinit ]]; then
  # (each with what it requires, in the order of their ranks; all of a unit's
  # atoms: a socket's activator and the like are not required by it)
  while read -r _ unit; do
    for atom in ${NEW_ATOMS[$unit]}; do
      [[ $atom == *-log ]] && continue
      dname "$atom"
      "${DINITCTL[@]}" --quiet start "$DN" || rc=4
    done
  done < <(for unit in ${start[@]+"${start[@]}"} ${stop_start[@]+"${stop_start[@]}"}; do
             printf '%s %s\n' "${NEW_UNIT_RANK[$unit]}" "$unit"
           done | sort -n)
  start_atoms=()
  # What the stops and restarts above took down with them (dependents
  # stopped by --force: nscd's nss-lookup.target, say) comes back: whatever
  # the new system starts at boot and dinit does not have started.
  listing=$("${DINITCTL[@]}" list 2>/dev/null)
  up=" "
  while IFS= read -r line; do
    [[ ${line:2:1} == [+s] ]] || continue
    line=${line:11}
    up+="${line%% *} "
  done <<< "$listing"
  while read -r _ unit; do
    for atom in ${NEW_ATOMS[$unit]}; do
      [[ $atom == *-log ]] && continue
      is_up "$atom" && continue
      dname "$atom"
      "${DINITCTL[@]}" --quiet start "$DN" || rc=4
    done
  done < <(for unit in "${!NEW_BOOT[@]}"; do
             [[ ${NEW_BOOT[$unit]} == 1 ]] && printf '%s %s\n' "${NEW_UNIT_RANK[$unit]}" "$unit"
           done | sort -n)
fi
if (( ${#start_atoms[@]} )); then
  now_up=" $(s6-rc -b -a list | tr '\n' ' ') "
  prev= batch=()
  flush() {
    if (( ${#batch[@]} )); then s6-rc -b -u change "${batch[@]}" || rc=4; fi
    batch=()
  }
  while IFS=$'\t' read -r rank atom; do
    [[ " ${start_atoms[*]} " == *" $atom "* ]] || continue
    [[ $now_up == *" $atom "* ]] && continue
    [[ $rank == "$prev" ]] || flush
    prev=$rank
    batch+=("$atom")
  done < "$new_db/ranks.tsv"
  flush
fi

# run-once jobs whose definition changed, in boot order
if (( ${#rerun[@]} )); then
  while read -r _ unit; do
    "$RUNTIME" job "$new_db/unit-data/$unit" || rc=4
  done < <(for unit in "${rerun[@]}"; do printf '%s %s\n' "${NEW_UNIT_RANK[$unit]}" "$unit"; done | sort -n)
fi

if (( ${#reload[@]} )); then
  echo "reloading the following units: $(list $(sorted "${reload[@]}"))"
  for unit in "${reload[@]}"; do
    if grep -Eq "^(U_N_RELOAD=[1-9]|U_RELOAD_SIGNAL='[A-Z])" "$new_db/unit-data/$unit" 2>/dev/null; then
      "$RUNTIME" reload "$new_db/unit-data/$unit" || rc=4
    fi
  done
fi

# the managers of the users that are logged in (or linger) follow
if [[ $action == switch || $action == test ]] && [[ -d /run/user-managers/.state ]]; then
  @userManager@ switch-all
fi

# systemd's last step is to start the active targets, which starts again
# whatever they want that is not running: services that failed (so that a
# switch to a configuration that still fails, fails again), oneshots that
# ran once at boot, units stopped by hand.
#
# Before that it restarts sysinit-reactivation.target, which starts what the
# target requires and is not active: systemd-tmpfiles-resetup, which does not
# run at boot, so that rules added since (a new user's home) are applied.
if [[ $action == switch || $action == test ]]; then
  systemctl_new=$toplevel/sw/bin/systemctl
  [[ -x $systemctl_new ]] || systemctl_new=systemctl
  if [[ -n ${NEW_HASH[sysinit-reactivation.target]-} ]]; then
    S6_SWITCH_SKIP="${rerun[*]-}" "$systemctl_new" start sysinit-reactivation.target >&2 || rc=4
  fi
  S6_SWITCH_SKIP="${rerun[*]-}" "$systemctl_new" start default.target >&2 || rc=4
fi

# --------------------------------------------------------------------------
# report

failed=()
for unit in ${stop_start[@]+"${stop_start[@]}"} ${restart[@]+"${restart[@]}"} ${start[@]+"${start[@]}"}; do
  [[ -r $STATE/$unit/state && $(< "$STATE/$unit/state") == failed ]] && failed+=("$unit")
done
if (( ${#failed[@]} )); then
  echo "warning: the following units failed: $(list $(sorted "${failed[@]}"))" >&2
  for unit in "${failed[@]}"; do
    atom=${NEW_ATOMS[$unit]%% *}
    [[ -r /var/log/s6/$atom/current ]] && { echo "--- $unit" >&2; tail -n 10 "/var/log/s6/$atom/current" >&2; }
  done
  rc=4
fi

booted_init=$(cat /run/booted-system/init-interface-version 2>/dev/null)
new_init=$(cat "$toplevel/init-interface-version" 2>/dev/null)
if [[ -n $booted_init && $booted_init != "$new_init" ]]; then
  echo "note: the init system itself has changed ($booted_init -> $new_init); reboot to run the new one." >&2
fi

exit $rc
