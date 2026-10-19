#!@shell@
# user-manager - one s6 supervision tree per logged-in user.
#
# `systemd --user` is a service manager of its own, started by PID 1 when the
# first session of a user opens and stopped when the last one closes.  Here
# the same is done in three parts:
#
#   hook      run by PAM (pam_exec) at session open and close; keeps count of
#             sessions and starts or stops the manager
#   run       the manager as a service of the system's s6: becomes the user,
#             with a clean environment, and runs `session`
#   session   (as the user) s6-svscan on /run/user-managers/.state/UID/service, the user's
#             compiled s6-rc database brought up, and a stop that takes the
#             services down in order
#
# The system-side services live in /run/user-managers, a scan directory of
# its own that the system service `user-managers` supervises.  That service
# is `supervise`, which also takes the managers of users that have no session
# left down again: not the hook, because anything the hook leaves behind is a
# process in the session's control group, and a session whose group is not
# empty when it ends never finishes closing.

# (PAM runs the hook with next to no environment: no PATH to speak of, so the
# system's is added, which is where `loginctl` is)
PATH=@path@:@defaultPath@${PATH:+:$PATH}
set -u

SELF=$0
SCAN=/run/user-managers
SESSIONS=$SCAN/.sessions
# what each manager keeps: its scan directory, s6-rc, the copy of the database,
# the state of its units.  Not in $XDG_RUNTIME_DIR, which the login manager
# removes as soon as the user has no session and does not linger: the
# manager has to be there until its services are stopped.
STATES=$SCAN/.state
DEFAULT_PATH='@defaultPath@'

log() { printf 'user-manager: %s\n' "$*" >&2; }

lookup() {
  # lookup UID -> sets name, gid, home, shell
  local entry
  entry=$(getent passwd "$1") || return 1
  IFS=: read -r name _ _ gid _ home shell <<< "$entry"
}

manager_dir() { printf '%s/user-%s' "$SCAN" "$1"; }

start_manager() {
  local uid=$1 dir
  dir=$(manager_dir "$uid")
  if [[ -d $dir ]]; then
    s6-svc -u "$dir" 2>/dev/null
    return 0
  fi
  [[ -d $SCAN ]] || { log "$SCAN is not there (the user-managers service is not running)"; return 1; }
  mkdir -p "$dir.new"
  printf '#!/bin/sh\nexec %s run %s\n' "$SELF" "$uid" > "$dir.new/run"
  chmod 0755 "$dir.new/run"
  mv "$dir.new" "$dir"
  s6-svscanctl -a "$SCAN"
}

stop_manager() {
  local uid=$1 dir gone i
  dir=$(manager_dir "$uid")
  [[ -d $dir ]] || return 0
  # The directory leaves the scan directory first.  s6-svscan starts a
  # supervisor again for any directory it finds without one, and a new
  # supervisor starts the service (there is no `down` file): so a manager
  # told to exit and only then removed comes back, now without a directory
  # to be told anything through.  A name with a dot in front is not a
  # service to s6-svscan; the supervisor does not mind being moved.
  gone=$SCAN/.gone-$uid
  rm -rf "$gone"
  mv "$dir" "$gone" || return 1
  s6-svscanctl -a "$SCAN" 2>/dev/null
  s6-svc -d "$gone" 2>/dev/null
  s6-svwait -D -t 45000 "$gone" 2>/dev/null
  s6-svc -x "$gone" 2>/dev/null
  # wait for the supervisor itself to go before taking its directory away
  for i in $(seq 100); do
    s6-svok "$gone" 2>/dev/null || break
    sleep 0.1
  done
  rm -rf "$gone"
  # the manager's own files go with it, and its control group (see cmd_run)
  rm -rf "${STATES:?}/${uid:?}"
  rmdir "/sys/fs/cgroup/user.slice/user-$uid.slice/user@$uid.service" \
    "/sys/fs/cgroup/user.slice/user-$uid.slice" 2>/dev/null
}

# Users that stay around without a session (loginctl enable-linger)
lingering() { [[ -e /var/lib/elogind/linger/$1 || -e /var/lib/systemd/linger/$1 ]]; }

# The login manager takes /run/user/UID away when the last session ends.  The
# manager of the user has to be down by then, so for as long as it runs the
# user is made to linger, and let go again once it is not.
templinger_on() {
  local user=$1 uid=$2
  command -v loginctl > /dev/null 2>&1 || return 0
  lingering "$user" && return 0
  if loginctl enable-linger "$user" 2> /dev/null; then
    : > "$SESSIONS/$uid.templinger"
  fi
}

templinger_off() {
  local user=$1 uid=$2
  if [[ -e $SESSIONS/$uid.templinger ]]; then
    rm -f "$SESSIONS/$uid.templinger"
    loginctl disable-linger "$user" 2> /dev/null
  fi
  # without a login manager nobody else is going to remove it
  if [[ -e $SESSIONS/$uid.createdrt ]]; then
    rm -f "$SESSIONS/$uid.createdrt"
    rm -rf "/run/user/${uid:?}"
  fi
}

# --------------------------------------------------------------------------
# PAM

cmd_hook() {
  local user=${PAM_USER-} type=${PAM_TYPE-} uid dir token t i
  [[ -n $user && -n $type ]] || exit 0
  uid=$(id -u "$user" 2>/dev/null) || exit 0
  # system accounts have no manager (systemd gives them "light" sessions,
  # which do not start one); root has one, as user@0.service under systemd
  (( uid == 0 || uid >= 1000 )) || exit 0
  dir=$SESSIONS/$uid
  # PAM_TYPE is open_session or close_session; PPID is the process that
  # opened the session, which is what tells two sessions apart
  token=$PPID
  case $type in
    open_session)
      # a manager that is just being taken down has to be gone first
      for i in $(seq 600); do
        [[ -e $SESSIONS/$uid.stopping ]] || break
        sleep 0.1
      done
      mkdir -p "$dir"
      : > "$dir/$token"
      rm -f "$SESSIONS/$uid.idle"
      if [[ ! -d /run/user/$uid ]]; then
        # no login manager has made it
        install -d -m 0700 -o "$uid" -g "$(id -g "$user")" "/run/user/$uid"
        : > "$SESSIONS/$uid.createdrt"
      fi
      local started=0
      start_manager "$uid" && started=1
      templinger_on "$user" "$uid"
      # As pam_systemd waits for user@UID.service: the session begins with
      # the user's services up (the session bus, which the next PAM module
      # tells the session about).  Not forever, as with systemd's timeout.
      if (( started )); then
        local mdir
        mdir=$(manager_dir "$uid")
        for i in $(seq 300); do
          [[ -e $STATES/$uid/units/.up ]] && break
          # (a manager that has died is not going to be up: as user@UID.service
          # failing to start, which the session does not wait for either)
          if s6-svok "$mdir" 2>/dev/null && [[ $(s6-svstat -o up "$mdir" 2>/dev/null) == false ]]; then
            break
          fi
          sleep 0.1
        done
      fi ;;
    close_session)
      rm -f "$dir/$token" ;;
  esac
  exit 0
}

# Sessions that ended without telling anyone leave their token behind.
prune_tokens() {
  local dir=$1 t
  for t in "$dir"/*; do
    [[ -e $t ]] || continue
    [[ -d /proc/${t##*/} ]] || rm -f "$t"
  done
}

# --------------------------------------------------------------------------
# the system service

# Users that stay around without a session (loginctl enable-linger) have a
# manager from boot on, as with systemd.
start_lingering() {
  local f name uid
  for f in /var/lib/elogind/linger/* /var/lib/systemd/linger/*; do
    [[ -e $f ]] || continue
    name=${f##*/}
    uid=$(id -u "$name" 2>/dev/null) || continue
    (( uid == 0 || uid >= 1000 )) || continue
    [[ -d $(manager_dir "$uid") ]] && continue
    # (one that is being taken down is not to come back)
    [[ -e $SESSIONS/$uid.stopping ]] && continue
    if [[ ! -d /run/user/$uid ]]; then
      # the login manager makes it for a lingering user too, but it may not be up yet
      install -d -m 0700 -o "$uid" -g "$(id -g "$name")" "/run/user/$uid" 2> /dev/null || continue
    fi
    start_manager "$uid"
  done
}

cmd_supervise() {
  local svpid dir uid now since name tokens
  mkdir -p "$SCAN" "$SESSIONS" /run/user

  s6-svscan -- "$SCAN" &
  svpid=$!

  # a manager has to be told to stop before the services it started
  stop_all() {
    trap '' TERM
    for dir in "$SCAN"/user-*; do
      [[ -d $dir ]] && s6-svc -d "$dir"
    done
    for dir in "$SCAN"/user-*; do
      [[ -d $dir ]] && s6-svwait -D -t 45000 "$dir"
    done
    s6-svscanctl -t "$SCAN"
  }
  trap stop_all TERM

  while kill -0 "$svpid" 2>/dev/null; do
    start_lingering
    for dir in "$SCAN"/user-*; do
      [[ -d $dir ]] || continue
      uid=${dir##*/user-}
      [[ -e $SESSIONS/$uid.stopping ]] && continue
      tokens=0
      if [[ -d $SESSIONS/$uid ]]; then
        prune_tokens "$SESSIONS/$uid"
        [[ -n $(ls -A "$SESSIONS/$uid" 2>/dev/null) ]] && tokens=1
      fi
      name=$(id -nu "$uid" 2>/dev/null) || name=
      # a session, or a lingering user (the temporary lingering this program
      # set up for a session does not count) keeps the manager
      if (( tokens )) || { lingering "$name" && [[ ! -e $SESSIONS/$uid.templinger ]]; }; then
        rm -f "$SESSIONS/$uid.idle"
        continue
      fi
      now=$EPOCHSECONDS
      if [[ ! -e $SESSIONS/$uid.idle ]]; then
        printf '%s\n' "$now" > "$SESSIONS/$uid.idle"
        continue
      fi
      since=$(< "$SESSIONS/$uid.idle")
      # a quick relogin keeps the manager
      (( now - since >= 5 )) || continue
      rm -f "$SESSIONS/$uid.idle"
      : > "$SESSIONS/$uid.stopping"
      ( stop_manager "$uid"
        templinger_off "$name" "$uid"
        # (not if somebody has logged in again in the meantime)
        rmdir "$SESSIONS/$uid" 2>/dev/null
        rm -f "$SESSIONS/$uid.stopping" ) &
    done
    # woken early by the trap
    sleep 2 &
    wait $!
  done
}

# --------------------------------------------------------------------------
# the service in the system's scan directory (root)

cmd_run() {
  local uid=$1 name gid home shell
  lookup "$uid" || { log "no user with uid $uid"; exit 1; }
  # (the parent can be looked into, not listed: nobody sees who has a manager)
  install -d -m 0711 "$STATES"
  rm -rf "${STATES:?}/${uid:?}"
  install -d -m 0700 -o "$uid" -g "$gid" "$STATES/$uid" || exit 1
  # The control group.  libsystemd (here libelogind) tells whose a process is
  # by its control group, and polkit asks it about the processes of the
  # user's services (rtkit's test, desktop services asking for things).
  # systemd keeps them in user-UID.slice/user@UID.service and polkit goes on
  # from the user to their session; elogind has nothing but sessions, each a
  # control group "/ID", and knows the user of a process only by the session
  # it is in.  With elogind the manager joins the user's session, then, as
  # what a session starts does on systems with elogind (a desktop's
  # pipewire); without a session (lingering) it is systemd's place.
  local cg=/sys/fs/cgroup/user.slice/user-$uid.slice/user@$uid.service sid=
  if [[ -r /run/systemd/users/$uid ]]; then
    local k v first=
    while IFS='=' read -r k v; do
      case $k in
        DISPLAY) sid=$v ;;
        SESSIONS) first=${v%% *} ;;
      esac
    done < "/run/systemd/users/$uid"
    [[ -n $sid ]] || sid=$first
  fi
  [[ -n $sid && -d /sys/fs/cgroup/$sid ]] && cg=/sys/fs/cgroup/$sid
  if [[ -e /sys/fs/cgroup/cgroup.procs ]] && mkdir -p "$cg" 2>/dev/null; then
    echo "$$" > "$cg/cgroup.procs" 2>/dev/null || log "cannot move into $cg"
  fi
  # A PAM session of service systemd-user around it, as user@UID.service has
  # (PAMName=systemd-user): what NixOS puts there is for the user's manager -
  # pam_mkhomedir with security.pam.services.systemd-user.makeHomeDir, limits.
  # unit-pam stays as root to close it.  If PAM says no, there is no manager,
  # as user@UID.service would fail; a system without that PAM service has
  # none to open.
  local pam=()
  [[ -e /etc/pam.d/systemd-user ]] && pam=(unit-pam -s systemd-user -u "$name" --)
  # setpriv and a clean environment: from here on this is the user's
  exec ${pam[@]+"${pam[@]}"} setpriv --reuid "$uid" --regid "$gid" --init-groups \
    env -i \
      HOME="$home" USER="$name" LOGNAME="$name" SHELL="$shell" \
      XDG_RUNTIME_DIR="/run/user/$uid" UNIT_SCOPE=user \
      UNIT_USER_STATE="$STATES/$uid" \
      PATH="$DEFAULT_PATH" \
      "$SELF" session "$uid"
}

# --------------------------------------------------------------------------
# the user's manager (as the user)

cmd_session() {
  local uid=$1 scandir rt st db svpid
  rt=$XDG_RUNTIME_DIR
  st=${UNIT_USER_STATE:?}
  scandir=$st/service
  [[ -d $rt ]] || { log "$rt does not exist"; exit 1; }

  # what NixOS sets for login shells: PATH, XDG_*, locale, …
  if [[ -r /etc/set-environment ]]; then
    # (written for login shells, which do not run with `set -u`)
    set +u -a
    # shellcheck disable=SC1091
    . /etc/set-environment
    set -u +a
  fi
  export UNIT_SCOPE=user XDG_RUNTIME_DIR=$rt UNIT_USER_STATE=$st
  # the user's session bus (the dbus user service listens there), as the
  # services of systemd's user manager have it in their environment
  export DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=$rt/bus}
  # for what is run for this manager from outside of it (`systemctl --user`)
  env -0 > "$st/environment"

  db=$(readlink -f /run/current-system/s6-db)/user
  [[ -d $db/compiled-boot ]] || { log "no database for user services in $db"; exit 1; }

  mkdir -p "$st/units" "$scandir" "${XDG_STATE_HOME:-$HOME/.local/state}/s6"
  # leftovers of an earlier manager of this user
  chmod -R u+w "$st"/s6-rc "$st"/s6-rc:* "$st"/db 2>/dev/null
  rm -rf "$st"/s6-rc "$st"/s6-rc:* "$st"/db 2>/dev/null
  : > "$st/units/.booting"

  # The databases are in the Nix store, read-only; the service directories
  # that s6-rc copies out of them have to be writable by their owner, because
  # that is where their supervisors keep their state.  So they are copied
  # first (they are small) with permissions that allow it.
  mkdir -p "$st/db"
  local which
  for which in compiled-boot compiled; do
    # (modes are kept: the run scripts are executable)
    cp -r --no-preserve=ownership "$db/$which" "$st/db/$which" \
      && chmod -R u+w "$st/db/$which" \
      || { log "cannot copy $db/$which"; exit 1; }
  done

  # what `systemctl --user` reads next to the compiled databases
  local f
  # (all the tables: partof.tsv was missing once, and PartOf= of users' units
  # did nothing)
  for f in "$db"/*.tsv "$db"/manifest.json "$db"/unit-data "$db"/units; do
    [[ -e $f ]] && ln -s "$f" "$st/db/${f##*/}"
  done

  s6-svscan -- "$scandir" &
  svpid=$!

  stop_all() {
    trap '' TERM INT
    s6-rc -l "$st/s6-rc" -v1 -bDa -t 60000 change 2>/dev/null
    s6-svscanctl -t "$scandir" 2>/dev/null
  }
  trap stop_all TERM INT

  # s6-rc-init needs the supervision tree to be up
  local i
  for i in $(seq 100); do
    s6-svscanctl -a "$scandir" 2>/dev/null && break
    sleep 0.1
  done

  s6-rc-init -c "$st/db/compiled-boot" -l "$st/s6-rc" "$scandir" \
    || { log "s6-rc-init failed"; stop_all; exit 1; }
  s6-rc -l "$st/s6-rc" -v1 -u change default
  adopt_strays "$st"
  s6-rc-update -l "$st/s6-rc" -v1 "$st/db/compiled"
  rm -f "$st/units/.booting"
  # (what a login waits for: see cmd_hook)
  : > "$st/units/.up"

  wait "$svpid"
}

# Services up behind s6-rc's back: what a socket brought up while the login's
# transaction held the lock was started with s6-svc -u (see systemctl's
# start), and s6-rc counts it down.  s6-rc-update would then replace its
# service directory, supervisor and program with it, whenever its run script
# changed (it names the database: at every switch) — pipewire went that way,
# and the sound with it.  So they are adopted first, as rc.init does for the
# system's.
adopt_strays() {
  local st=$1 up known d a adopt=()
  up=" $(s6-rc -l "$st/s6-rc" -b -a list 2>/dev/null | tr '\n' ' ') "
  known=" $(s6-rc-db -l "$st/s6-rc" list services 2>/dev/null | tr '\n' ' ') "
  for d in "$st"/service/*; do
    a=${d##*/}
    [[ $known == *" $a "* && $up != *" $a "* ]] || continue
    [[ $(s6-svstat -o up "$d" 2>/dev/null) == true ]] && adopt+=("$a")
  done
  if (( ${#adopt[@]} )); then
    log "services started behind s6-rc: ${adopt[*]}"
    s6-rc -l "$st/s6-rc" -b -u change "${adopt[@]}" > /dev/null 2>&1
  fi
}

# --------------------------------------------------------------------------
# a configuration switch, for the managers that are running

# (as the user) bring this manager's services to the new system's user
# database, restarting what changed, as switch-to-configuration does for the
# system's; then run the user activation again, as it does for everybody.
cmd_user_switch() {
  local st=${UNIT_USER_STATE:?} new live old unit hash restart reload stop atoms atom
  new=$(readlink -f /run/current-system/s6-db)/user
  [[ -d $new/compiled ]] || exit 0
  live=$(readlink -f "$st/db/index.tsv" 2>/dev/null) || live=
  old=${live%/*}
  if [[ -n $old && $old != "$new" && -r $old/switch.tsv && -r $new/switch.tsv ]]; then
    local -A old_hash=() new_exists=()
    while IFS=$'\t' read -r unit hash restart reload stop atoms; do old_hash[$unit]=$hash; done < "$old/switch.tsv"
    local conv=$st/conversion.$$ n=$st/db/compiled.$$ up reloads=()
    : > "$conv"
    up=" $(s6-rc -l "$st/s6-rc" -b -a list 2>/dev/null | tr '\n' ' ') "
    while IFS=$'\t' read -r unit hash restart reload stop atoms; do
      [[ -n ${old_hash[$unit]-} && ${old_hash[$unit]} != "$hash" ]] || continue
      [[ $restart == 1 ]] || continue
      case $unit in *.target|*.device) continue ;; esac
      # reloadIfChanged, as the system's switch does: a restart of dbus took
      # pipewire, which needs it, along — and the sound of a call with it
      if [[ $reload == 1 ]]; then
        [[ $up == *" ${atoms%% *} "* ]] && reloads+=("$unit")
        continue
      fi
      for atom in $atoms; do
        [[ $up == *" $atom "* ]] && printf '"%s" restart\n' "$atom" >> "$conv"
      done
    done < "$new/switch.tsv"
    adopt_strays "$st"
    cp -r --no-preserve=ownership "$new/compiled" "$n" && chmod -R u+w "$n" \
      || { log "cannot copy the new user database"; rm -f "$conv"; exit 1; }
    s6-rc-update -l "$st/s6-rc" -b -f "$conv" "$n" > /dev/null 2>&1 \
      || log "s6-rc-update of the user's services did not complete"
    # (the copies of earlier switches: one was left behind at each)
    local cur d
    cur=$(readlink "$st/s6-rc/compiled")
    for d in "$st"/db/compiled.*; do
      [[ $d == "$cur" ]] || { chmod -R u+w "$d"; rm -rf "$d"; }
    done
    # what `systemctl --user` reads next to the compiled databases
    local f
    for f in "$new"/*.tsv "$new"/manifest.json "$new"/unit-data "$new"/units; do
      [[ -e $f ]] && ln -sfn "$f" "$st/db/${f##*/}"
    done
    rm -f "$conv"
    s6-rc -l "$st/s6-rc" -b -u change default > /dev/null 2>&1
    for unit in ${reloads[@]+"${reloads[@]}"}; do
      PATH=$PATH:$DEFAULT_PATH systemctl --user reload "$unit" > /dev/null 2>&1 \
        || log "reload of $unit failed"
    done
  fi
  # the activation scripts of the user run at every switch
  PATH=$PATH:$DEFAULT_PATH systemctl --user restart nixos-activation.service > /dev/null 2>&1 || true
}

# (as root) every running manager, as its user
cmd_switch_all() {
  local d uid name gid home shell
  for d in "$STATES"/*; do
    [[ -d $d/s6-rc ]] || continue
    uid=${d##*/}
    lookup "$uid" || continue
    setpriv --reuid "$uid" --regid "$gid" --init-groups \
      env -i HOME="$home" USER="$name" LOGNAME="$name" SHELL="$shell" \
        XDG_RUNTIME_DIR="/run/user/$uid" UNIT_SCOPE=user UNIT_USER_STATE="$d" \
        PATH="$DEFAULT_PATH" \
        "$SELF" user-switch || true
  done
}

case ${1-} in
  hook) cmd_hook ;;
  user-switch) cmd_user_switch ;;
  switch-all) cmd_switch_all ;;
  supervise) cmd_supervise ;;
  start) start_manager "${2:?uid}" ;;
  stop) stop_manager "${2:?uid}" ;;
  run) cmd_run "${2:?uid}" ;;
  session) cmd_session "${2:?uid}" ;;
  *)
    echo "usage: user-manager hook|supervise|start UID|stop UID" >&2
    exit 100 ;;
esac
