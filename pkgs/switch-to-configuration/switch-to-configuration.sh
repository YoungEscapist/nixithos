#!@shell@
# switch-to-configuration - make a built system the one that runs.
#
#   switch-to-configuration switch|boot|test|dry-activate
#
# Same contract as the NixOS program of that name (it is what nixos-rebuild
# calls): `boot` only updates the boot loader, `test` only changes the
# running system, `switch` does both, `dry-activate` says what would happen.
#
# Changing the running system means:
#   1. stop the units whose definition changed and that want to be stopped
#      before their configuration is replaced (the default, `stopIfChanged`);
#   2. run the activation script (/etc, users, …);
#   3. hand the new service database to s6-rc-update, which stops what no
#      longer exists and restarts what we tell it has changed;
#   4. start what is new, reload what asked to be reloaded.
# Units that did not change are not touched.

PATH=@path@:$PATH
RUNTIME=@runtime@
set -u

toplevel=${TOPLEVEL:?switch-to-configuration must be run through the system closure}
action=${1-}

case $action in
  switch|boot|test|dry-activate) ;;
  *)
    cat >&2 <<EOF
Usage: $0 [switch|boot|test|dry-activate]

switch:       make the configuration the boot default and activate now
boot:         make the configuration the boot default
test:         activate the configuration, but don't make it the boot default
dry-activate: show what would be done if this configuration were activated
EOF
    exit 1 ;;
esac

STATE=/run/units
SCAN=/run/service

mkdir -p /run/nixos
exec 9> /run/nixos/switch-to-configuration.lock
flock 9 || { echo "could not acquire the switch lock" >&2; exit 1; }

if [[ -z ${NIXOS_NO_CHECK-} && -n ${PRE_SWITCH_CHECK-} ]]; then
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
live=$(readlink -f /run/s6-rc/compiled 2>/dev/null) || live=
old_db=${live%/*}

if [[ -z $live || ! -r $old_db/switch.tsv ]]; then
  # Not running on s6-rc (a chroot, an installer): there is nothing to
  # reconcile, just lay down the configuration.
  if [[ $action == dry-activate ]]; then exec "$toplevel/dry-activate" "$toplevel"; fi
  echo "activating the configuration..."
  exec "$toplevel/activate" "$toplevel"
fi

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
up=$(s6-rc -b -a list 2>/dev/null) || { echo "s6-rc is not answering" >&2; exit 1; }
up=" ${up//$'\n'/ } "
is_up() { [[ $up == *" $1 "* ]]; }

# Is the unit doing something right now?  (A oneshot that has run and is
# done counts, as long as it "remains after exit".)
is_active() {
  local unit=$1 atom st=
  atom=${OLD_ATOMS[$unit]%% *}
  [[ -n $atom ]] || return 1
  is_up "$atom" || return 1
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

removed=() stop_start=() restart=() reload=() skipped=() rerun=()
for unit in "${!OLD_HASH[@]}"; do
  if [[ -z ${NEW_HASH[$unit]-} ]]; then
    is_active "$unit" && removed+=("$unit")
    continue
  fi
  [[ ${OLD_HASH[$unit]} == "${NEW_HASH[$unit]}" ]] && continue
  if is_run_once "$unit"; then
    rerun+=("$unit")
    continue
  fi
  is_active "$unit" || continue
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
for unit in ${stop_start[@]+"${stop_start[@]}"}; do
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

if [[ $new_db != "$old_db" ]]; then
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
