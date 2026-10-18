#!@bash@
# unit-runtime - runs one compiled unit under s6.
#
# unitc turns every systemd unit into a small data file (shell variables and
# functions) plus s6-rc service definitions whose scripts are one-liners
# calling this program:
#
#   unit-runtime run        DATA          longrun ./run
#   unit-runtime finish     DATA CODE SIG longrun ./finish
#   unit-runtime up|down    DATA          Type=oneshot services
#   unit-runtime stop-hook  DATA          ExecStop= of a longrun
#   unit-runtime reload     DATA          ExecReload=
#   unit-runtime job        DATA          run a service once, outside s6-rc
#                                         (timers, repeated oneshots)
#   unit-runtime mount-up|mount-down|swap-up|swap-down|socket-up|socket-down DATA
#   unit-runtime device     NAME PATH TIMEOUT_MS HARD
#   unit-runtime timer      DATA
#   unit-runtime device-watch DBDIR       start units as devices appear
#   unit-runtime log        NAME          the per-service logger
#
# It implements the part of systemd.exec(5)/systemd.service(5) that is about
# starting a process in the right context: environment, credentials,
# directories, user, limits, readiness, restart policy, clean-up.

set -f -u

# The logger of a service is by far the most frequent call (every service has
# one, and they all start together at boot) and needs nothing of the rest.
# Bash executes a script as it reads it, so answering here leaves the
# remaining lines unparsed.
if [[ ${1-} == log && ${UNIT_SCOPE-} != user ]]; then
  PATH='@path@'
  mkdir -p -- '@logDir@'/"$2"
  # (/etc/units/console-log names a terminal that gets the lines as well)
  if [[ -r /etc/units/console-log ]] && read -r tty < /etc/units/console-log && [[ -w $tty ]]; then
    # shellcheck disable=SC2086
    exec s6-log -d3 -b -- @logScript@ '@logDir@'/"$2" "p$2: " 1 > "$tty"
  fi
  # shellcheck disable=SC2086
  exec s6-log -d3 -b -- @logScript@ '@logDir@'/"$2"
fi

# A target that is reached says so, in the journal (see cmd_target_up); on the
# boot's way from sysinit.target to the end, so it is as cheap.
if [[ ${1-} == target-up && ${UNIT_SCOPE-} != user ]]; then
  PATH='@path@'
  set +u
  # shellcheck disable=SC1090
  source "$2" || exit 100
  mkdir -p -- "/run/units/$U_UNIT"
  t=$EPOCHREALTIME
  printf '%(%F %T)T.%s000  Reached target %s.\n' "${t%.*}" "${t#*.}" "${U_DESCRIPTION:-$U_UNIT}" >> "/run/units/$U_UNIT/journal"
  exit 0
fi

trap '' PIPE

# Two scopes: the system's services (root, /run/service) and a user's
# (UNIT_SCOPE=user in the environment of that user's service manager, whose
# environment is what its services start from).
if [[ ${UNIT_SCOPE-} == user ]]; then
  scope=user
else
  scope=system
  # Units get the environment their unit file describes, not ours (but for
  # what an accepted connection brings along).  Done here rather than by
  # starting again under `env -i`: a second start of this script is a good
  # part of the time a service takes to restart (getty after a logout, which
  # tests type at right away).  Functions that came with the environment go
  # too; none of ours is defined yet.
  if [[ $(type -t compgen) == builtin ]]; then
    unset -f $(compgen -A function)
    for __v in $(compgen -e); do
      case $__v in
        UNIT_ACCEPT_INSTANCE|REMOTE_ADDR|REMOTE_PORT) ;;
        *) unset -v "$__v" 2>/dev/null || export -n "$__v" ;;
      esac
    done
    unset __v
  elif [[ ${__UNIT_RT_CLEAN-} != 1 ]]; then
    # (a bash without programmable completion: start again, empty-handed)
    keep=()
    for v in UNIT_ACCEPT_INSTANCE REMOTE_ADDR REMOTE_PORT; do
      [[ -n ${!v-} ]] && keep+=("$v=${!v}")
    done
    exec @env@ -i __UNIT_RT_CLEAN=1 ${keep[@]+"${keep[@]}"} "$BASH" "$0" "$@"
  fi
  unset __UNIT_RT_CLEAN
fi

# The runtime itself works in the C locale, with an LC_ALL of its own that is
# not exported (services do not see it): bash otherwise loads the locale anew
# at every assignment to LANG or LC_*, and the LANG of /etc/locale.conf, which
# every service gets, costs milliseconds to load each time.
[[ -n ${LC_ALL-} ]] || LC_ALL=C

# rm, rmdir and sleep as bash builtins (loadable, from bash itself): the
# runtime runs them a dozen times per start and stop, each a fork and an exec
# otherwise.  (Not mkdir: the loadable one applies the umask to `-m MODE`,
# so a RuntimeDirectoryMode=0755 under UMask=0077 came out 0700.)
for __b in rm rmdir sleep; do
  enable -f '@bashLoadables@'/"$__b" "$__b" 2>/dev/null
done
unset __b

# `mkdir -p` of directories that are all there already (the unit's state
# directory, at every start and stop) does not need a process either.
mkdir() {
  if [[ ${1-} == -p && $# -ge 2 ]]; then
    local d
    for d in "${@:2}"; do
      [[ $d == -- || -d $d ]] || { command mkdir "$@"; return; }
    done
    return 0
  fi
  command mkdir "$@"
}

export PATH='@path@'
readonly RT_SELF=$0
readonly RT_PATH=$PATH
readonly RT_LOGSCRIPT='@logScript@'
readonly RT_SANDBOX='@sandbox@'
readonly RT_NFD='@notificationFd@'
readonly RT_SEP=$'\x1f'

if [[ $scope == user ]]; then
  : "${XDG_RUNTIME_DIR:?user services need XDG_RUNTIME_DIR}"
  : "${HOME:?}"
  # The manager keeps its own files out of $XDG_RUNTIME_DIR: the login manager
  # takes that away when the user's last session (or lingering) ends, and the
  # manager has to be reachable until its services are stopped.
  RT_STATE=${UNIT_USER_STATE:-$XDG_RUNTIME_DIR}/units
  RT_CGROUP=
  RT_LOGDIR=${XDG_STATE_HOME:-$HOME/.local/state}/s6
  RT_SCANDIR=${UNIT_USER_STATE:-$XDG_RUNTIME_DIR}/service
  RT_DEFAULT_PATH="/run/wrappers/bin:/etc/profiles/per-user/${USER:-$(id -un)}/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin"
  # where RuntimeDirectory=, StateDirectory=, … live
  RT_DIR_RUNTIME=$XDG_RUNTIME_DIR
  RT_DIR_STATE=${XDG_STATE_HOME:-$HOME/.local/state}
  RT_DIR_CACHE=${XDG_CACHE_HOME:-$HOME/.cache}
  RT_DIR_LOGS=${XDG_STATE_HOME:-$HOME/.local/state}/log
  RT_DIR_CONF=${XDG_CONFIG_HOME:-$HOME/.config}
  RT_CREDS=$XDG_RUNTIME_DIR/credentials
else
  RT_STATE=/run/units
  RT_CGROUP=/sys/fs/cgroup/units
  RT_LOGDIR='@logDir@'
  RT_SCANDIR=/run/service
  RT_DEFAULT_PATH='@defaultPath@'
  RT_DIR_RUNTIME=/run
  RT_DIR_STATE=/var/lib
  RT_DIR_CACHE=/var/cache
  RT_DIR_LOGS=/var/log
  RT_DIR_CONF=/etc
  RT_CREDS=/run/credentials
fi
RT_FDHOLDER=$RT_STATE/.fdholder
RT_CONSOLE=
if [[ $scope == system && -r /etc/units/console-log ]]; then
  read -r RT_CONSOLE < /etc/units/console-log
  [[ -w $RT_CONSOLE ]] || RT_CONSOLE=
fi

U_UNIT=unit-runtime

msg()  { printf '%s: %s\n' "$U_UNIT" "$*" >&2; }
warn() { printf '%s: warning: %s\n' "$U_UNIT" "$*" >&2; }

# --------------------------------------------------------------------------
# loading

load() {
  local data=$1
  [[ -r $data ]] || { msg "cannot read unit data $data"; exit 100; }
  __u_spec_H=$(< /proc/sys/kernel/hostname)
  __u_spec_l=${__u_spec_H%%.*}
  __u_spec_q=$__u_spec_H
  __u_spec_m=
  [[ -r /etc/machine-id ]] && __u_spec_m=$(< /etc/machine-id)
  __u_spec_b=$(< /proc/sys/kernel/random/boot_id)
  __u_spec_b=${__u_spec_b//-/}
  __u_spec_v=$(< /proc/sys/kernel/osrelease)
  __u_spec_a=$HOSTTYPE
  case $__u_spec_a in x86_64) __u_spec_a=x86-64 ;; aarch64) __u_spec_a=arm64 ;; i?86) __u_spec_a=x86 ;; esac
  # %o: the ID of /etc/os-release (nixithos, or nixos without the branding)
  __u_spec_o=nixos
  if [[ -r /etc/os-release ]]; then
    local k v
    while IFS='=' read -r k v; do
      if [[ $k == ID ]]; then v=${v#\"}; __u_spec_o=${v%\"}; break; fi
    done < /etc/os-release
  fi
  __u_spec_w=
  if [[ $scope == user ]]; then
    # In a user's services these name that user's directories; for the
    # system's they were filled in when the unit was compiled.
    __u_spec_t=$RT_DIR_RUNTIME
    __u_spec_S=$RT_DIR_STATE
    __u_spec_C=$RT_DIR_CACHE
    __u_spec_L=$RT_DIR_LOGS
    __u_spec_E=$RT_DIR_CONF
    __u_spec_h=$HOME
    __u_spec_u=${USER:-$(id -un)}
    __u_spec_U=$(id -u)
    __u_spec_g=$(id -gn)
    __u_spec_G=$(id -g)
  fi
  # shellcheck disable=SC1090
  source "$data"
  sd=$RT_STATE/$U_UNIT
  # %d: where LoadCredential= puts the unit's credentials (prepare_creds)
  __u_spec_d=$RT_CREDS/$U_UNIT
  cg=$RT_CGROUP/$U_ATOM
  mkdir -p "$sd"
}

set_state() {
  local was=
  [[ -r $sd/state ]] && was=$(< "$sd/state")
  printf '%s\n' "$1" > "$sd/state"
  [[ $# -gt 1 ]] && printf '%s\n' "$2" > "$sd/result"
  printf '%s\n' "${EPOCHSECONDS}" > "$sd/since"
  if [[ $1 != "$was" || $1 == activating ]]; then
    case $1 in
      activating)
        if [[ ${2-} == auto-restart ]]; then jlog "Scheduled restart job."; else jlog "Starting ${U_DESCRIPTION:-$U_UNIT}..."; fi ;;
      active)
        if [[ ${2-} == exited || ${2-} == mounted ]]; then jlog "Finished ${U_DESCRIPTION:-$U_UNIT}."; else jlog "Started ${U_DESCRIPTION:-$U_UNIT}."; fi ;;
      inactive)
        # (never started: a condition kept it from running)
        if [[ ${2-} == condition ]]; then :
        elif [[ ${U_TYPE-} == oneshot && ${2-} == success && $was != active ]]; then
          # (ran to its end; one that stays active is stopped, below)
          jlog "$U_UNIT: Deactivated successfully."
          jlog "Finished ${U_DESCRIPTION:-$U_UNIT}."
        elif [[ $was == active || $was == deactivating ]]; then
          [[ ${2-} == success ]] && jlog "$U_UNIT: Deactivated successfully."
          jlog "Stopped ${U_DESCRIPTION:-$U_UNIT}."
        fi
        trigger_on_success ${2-} ;;
      failed)
        jlog "$U_UNIT: Failed with result '${2-failed}'."
        jlog "Failed to start ${U_DESCRIPTION:-$U_UNIT}."
        echo_failure "${2-failed}"
        trigger OnFailure ${U_ON_FAILURE[@]+"${U_ON_FAILURE[@]}"} ;;
    esac
  fi
  return 0
}

# The lines systemd puts in the journal about a unit ("Started …", "Reloaded
# …"); the service's own output is in its s6-log directory, and journalctl
# puts the two together.
jlog() {
  local t=$EPOCHREALTIME
  printf '%(%F %T)T.%s000  %s\n' "${t%.*}" "${t#*.}" "$*" >> "$sd/journal" 2>/dev/null
  # (a VM that is to log to its console: see s6.logging in the loggers)
  if [[ -n ${RT_CONSOLE-} ]]; then printf 'systemd[1]: %s\n' "$*" >> "$RT_CONSOLE" 2>/dev/null; fi
  return 0
}

# s6.logging.echoFailures: the end of the log of a unit that failed, in the
# kernel log (and so on the console).  In the background: the log is written
# by another process, a moment later.
echo_failure() {
  [[ $scope == system && -e /etc/units/echo-failures && -w /dev/kmsg ]] || return 0
  (
    sleep 0.5
    {
      echo "<4>[$U_UNIT failed: $1]"
      tail -n 30 "$RT_LOGDIR/${U_ATOM:-$U_UNIT}/current" 2>/dev/null | cut -c1-900 | sed 's/^/<4>    /'
    } > /dev/kmsg 2>/dev/null
  ) > /dev/null 2>&1 &
  return 0
}

trigger_on_success() {
  [[ ${1-} == success ]] || return 0
  trigger OnSuccess ${U_ON_SUCCESS[@]+"${U_ON_SUCCESS[@]}"}
}

# OnFailure= and OnSuccess=: the named units are started, without waiting (we
# may be in the middle of a transaction that a start from here would join).
trigger() {
  local what=$1 flag=()
  shift
  (( $# )) || return 0
  [[ $scope == user ]] && flag=(--user)
  msg "$what=: starting $*"
  PATH=$PATH:$RT_DEFAULT_PATH systemctl ${flag[@]+"${flag[@]}"} start --no-block "$@" > /dev/null 2>&1 || true
}

# --------------------------------------------------------------------------
# conditions

is_true() {
  case ${1,,} in 1|yes|true|on|y|t) return 0 ;; esac
  return 1
}

detect_virt() {
  # prints "container:NAME", "vm:NAME" or "none"
  local v
  if [[ -e /run/systemd/container ]]; then
    printf 'container:%s\n' "$(< /run/systemd/container)"; return
  fi
  if [[ -e /.dockerenv ]]; then printf 'container:docker\n'; return; fi
  if [[ -r /proc/1/environ ]] && v=$(tr '\0' '\n' < /proc/1/environ | sed -n 's/^container=//p') && [[ -n $v ]]; then
    printf 'container:%s\n' "$v"; return
  fi
  v=
  [[ -r /sys/class/dmi/id/sys_vendor ]] && v=$(< /sys/class/dmi/id/sys_vendor)
  [[ -r /sys/class/dmi/id/product_name ]] && v+=" $(< /sys/class/dmi/id/product_name)"
  case $v in
    *QEMU*|*KVM*) printf 'vm:kvm\n' ;;
    *VMware*) printf 'vm:vmware\n' ;;
    *innotek*|*VirtualBox*) printf 'vm:oracle\n' ;;
    *Xen*) printf 'vm:xen\n' ;;
    *Microsoft*Virtual*) printf 'vm:microsoft\n' ;;
    *Bochs*) printf 'vm:bochs\n' ;;
    *Parallels*) printf 'vm:parallels\n' ;;
    *)
      if grep -qw hypervisor /proc/cpuinfo 2>/dev/null; then printf 'vm:vm-other\n'; else printf 'none\n'; fi ;;
  esac
}

check_one() {
  local name=$1 val=$2 v w
  case $name in
    PathExists) [[ -e $val ]] ;;
    PathExistsGlob) ( set +f; compgen -G "$val" > /dev/null ) ;;
    PathIsDirectory) [[ -d $val ]] ;;
    PathIsSymbolicLink) [[ -L $val ]] ;;
    PathIsMountPoint) mountpoint -q "$val" ;;
    PathIsReadWrite)
      [[ -e $val ]] || return 1
      v=$(findmnt -n -o OPTIONS -T "$val" 2>/dev/null) || return 1
      [[ ,$v, == *,rw,* ]] ;;
    PathIsEncrypted) return 1 ;;
    DirectoryNotEmpty) [[ -d $val && -n $(ls -A "$val" 2>/dev/null) ]] ;;
    FileNotEmpty) [[ -s $val ]] ;;
    FileIsExecutable) [[ -f $val && -x $val ]] ;;
    KernelCommandLine)
      for w in $(< /proc/cmdline); do
        if [[ $val == *=* ]]; then [[ $w == "$val" ]] && return 0
        else [[ $w == "$val" || $w == "$val="* ]] && return 0
        fi
      done
      return 1 ;;
    Virtualization)
      v=$(detect_virt)
      case ${val,,} in
        yes|true|1) [[ $v != none ]] ;;
        no|false|0) [[ $v == none ]] ;;
        vm) [[ $v == vm:* ]] ;;
        container) [[ $v == container:* ]] ;;
        *) [[ ${v#*:} == "$val" ]] ;;
      esac ;;
    Capability) return 0 ;;
    ACPower)
      v=1
      set +f
      for w in /sys/class/power_supply/*/online; do
        [[ -r $w ]] || continue
        v=0
        [[ $(< "$w") == 1 ]] && { v=1; break; }
      done
      set -f
      if is_true "$val"; then (( v == 1 )); else (( v == 0 )); fi ;;
    FirstBoot|NeedsUpdate) ! is_true "$val" ;;
    User)
      # whoever runs the unit's manager: root for the system's, the user for theirs
      case $val in
        @system) (( $(id -u) <= 999 )) ;;
        *[!0-9]*) [[ $val == "$(id -un)" ]] ;;
        *) [[ $val == "$(id -u)" ]] ;;
      esac ;;
    Group)
      case $val in
        *[!0-9]*) [[ " $(id -Gn) " == *" $val "* ]] ;;
        *) [[ " $(id -G) " == *" $val "* ]] ;;
      esac ;;
    Host) [[ $__u_spec_H == $val || $__u_spec_m == "$val" ]] ;;
    Architecture) [[ $val == native || $val == "$__u_spec_a" ]] ;;
    KernelVersion) [[ $__u_spec_v == $val ]] ;;
    Security)
      case $val in
        selinux) [[ -d /sys/fs/selinux ]] ;;
        apparmor) [[ -d /sys/kernel/security/apparmor ]] ;;
        tpm2) [[ -e /sys/class/tpmrm ]] ;;
        ima) [[ -d /sys/kernel/security/ima ]] ;;
        smack) [[ -d /sys/fs/smackfs ]] ;;
        audit) [[ -e /proc/self/loginuid ]] ;;
        *) return 1 ;;
      esac ;;
    ControlGroupController)
      [[ $val == v2 ]] && return 0
      [[ -r /sys/fs/cgroup/cgroup.controllers && " $(< /sys/fs/cgroup/cgroup.controllers) " == *" $val "* ]] ;;
    KernelModuleLoaded) [[ -d /sys/module/${val//-/_} ]] ;;
    # the environment of the service manager, as with systemd: a user's
    # (what it started with, and what `systemctl --user set-environment`
    # added: gnome-session's XDG_SESSION_TYPE for gnome-shell's
    # AssertEnvironment=), or PID 1's
    Environment)
      local en=${val%%=*} ev= eset=0
      if [[ $scope == user ]]; then
        if [[ -f $RT_STATE/.env/$en ]]; then ev=$(< "$RT_STATE/.env/$en"); eset=1
        elif [[ -v $en ]]; then ev=${!en}; eset=1
        fi
      elif [[ -r /proc/1/environ ]]; then
        local e
        while IFS= read -r -d '' e; do
          [[ ${e%%=*} == "$en" ]] && { ev=${e#*=}; eset=1; }
        done < /proc/1/environ
      fi
      (( eset )) || return 1
      [[ $val != *=* || $ev == "${val#*=}" ]] ;;
    Credential) return 1 ;;
    *) return 0 ;;
  esac
}

# conditions ARRAYNAME -> 0 if they hold
conditions() {
  local -n list=$1
  local entry name trigger negate val ok any_trigger=0 trigger_ok=0
  for entry in ${list[@]+"${list[@]}"}; do
    IFS=$RT_SEP read -r name trigger negate val <<< "$entry"
    if check_one "$name" "$val"; then ok=1; else ok=0; fi
    (( negate )) && ok=$(( 1 - ok ))
    if (( trigger )); then
      any_trigger=1
      (( ok )) && trigger_ok=1
    elif (( ! ok )); then
      __u_failed_condition="$1:$name=$val"
      return 1
    fi
  done
  if (( any_trigger && ! trigger_ok )); then
    __u_failed_condition="$1:(no triggering condition held)"
    return 1
  fi
  return 0
}

# --------------------------------------------------------------------------
# control groups: one per unit, so that stopping a unit stops everything it
# started, and so that resource limits have something to apply to.

cgroup_enter() {
  [[ -n $RT_CGROUP ]] || return 0
  [[ -w /sys/fs/cgroup/cgroup.procs ]] || return 0
  if [[ ! -d $RT_CGROUP ]]; then
    mkdir -p "$RT_CGROUP" 2>/dev/null || return 0
    local c
    for c in cpu memory pids io cpuset; do
      { echo "+$c" > /sys/fs/cgroup/cgroup.subtree_control; } 2>/dev/null
      { echo "+$c" > "$RT_CGROUP/cgroup.subtree_control"; } 2>/dev/null
    done
  fi
  mkdir -p "$cg" 2>/dev/null || return 0
  { echo $$ > "$cg/cgroup.procs"; } 2>/dev/null || return 0
  local entry file val total
  for entry in ${U_CGROUP_SET[@]+"${U_CGROUP_SET[@]}"}; do
    file=${entry%%"$RT_SEP"*} val=${entry#*"$RT_SEP"}
    if [[ $val == *% ]]; then
      case $file in
        memory.*)
          total=$(sed -n 's/^MemTotal: *\([0-9]*\) kB/\1/p' /proc/meminfo)
          val=$(( total * 1024 / 100 * ${val%\%} )) ;;
        pids.max) val=$(( $(< /proc/sys/kernel/pid_max) / 100 * ${val%\%} )) ;;
      esac
    fi
    { echo "$val" > "$cg/$file"; } 2>/dev/null || warn "cannot set $file=$val"
  done
}

cgroup_leave() {
  [[ -n $RT_CGROUP ]] || return 0
  { echo $$ > /sys/fs/cgroup/cgroup.procs; } 2>/dev/null
  return 0
}

cgroup_empty() {
  [[ -r $cg/cgroup.procs ]] || return 0
  [[ -z $(< "$cg/cgroup.procs") ]]
}

# cgroup_kill GRACE_SECONDS: apply KillMode= to whatever is left of the unit
cgroup_kill() {
  local grace=${1:-5} pid i pg=
  if [[ ! -d $cg ]]; then
    # no control group (a user's service, or no cgroup2): the process group
    # that s6-supervise gave the service is the next best thing
    [[ -r $sd/pgid ]] && pg=$(< "$sd/pgid")
    if [[ -n $pg ]] && (( pg > 1 )); then
      case ${U_KILL_MODE-control-group} in
        none|process) ;;
        *)
          kill -s "${U_KILL_SIGNAL-TERM}" -- "-$pg" 2>/dev/null
          for (( i = 0; i < grace * 10; i++ )); do
            kill -0 -- "-$pg" 2>/dev/null || break
            sleep 0.1
          done
          if kill -0 -- "-$pg" 2>/dev/null && (( ${U_SEND_SIGKILL-1} )); then
            kill -s KILL -- "-$pg" 2>/dev/null
          fi ;;
      esac
    fi
    return 0
  fi
  case ${U_KILL_MODE-control-group} in
    none|process) ;;
    *)
      if ! cgroup_empty; then
        if [[ ${U_KILL_MODE-} != mixed ]]; then
          for pid in $(< "$cg/cgroup.procs"); do
            kill -s "${U_KILL_SIGNAL-TERM}" "$pid" 2>/dev/null
            (( ${U_SEND_SIGHUP-0} )) && kill -s HUP "$pid" 2>/dev/null
            kill -s CONT "$pid" 2>/dev/null
          done
          for (( i = 0; i < grace * 10; i++ )); do
            cgroup_empty && break
            sleep 0.1
          done
        fi
        if ! cgroup_empty && (( ${U_SEND_SIGKILL-1} )); then
          if [[ -w $cg/cgroup.kill ]]; then
            echo 1 > "$cg/cgroup.kill"
          else
            for pid in $(< "$cg/cgroup.procs"); do kill -s KILL "$pid" 2>/dev/null; done
          fi
          for (( i = 0; i < 20; i++ )); do
            cgroup_empty && break
            sleep 0.1
          done
        fi
      fi ;;
  esac
  # (kept for a service that is restarted right away: see cmd_finish)
  [[ ${2-} == keep ]] || rmdir "$cg" 2>/dev/null
  return 0
}

# --------------------------------------------------------------------------
# execution environment

load_env_file() {
  local f=$1 optional=0 line key val cont=
  if [[ $f == -* ]]; then optional=1; f=${f#-}; fi
  # systemd drops a setting whose path is not absolute, with a warning
  if [[ $f != /* ]]; then
    msg "EnvironmentFile=$f is not an absolute path, ignoring"
    return 0
  fi
  if [[ ! -r $f ]]; then
    (( optional )) && return 0
    msg "cannot read EnvironmentFile=$f"
    return 1
  fi
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ -n $cont ]]; then line=$cont$line; cont=; fi
    if [[ $line == *\\ ]]; then cont=${line%\\}; continue; fi
    line=${line#"${line%%[![:space:]]*}"}
    [[ -z $line || $line == \#* || $line == \;* || $line != *=* ]] && continue
    key=${line%%=*}
    val=${line#*=}
    key=${key%"${key##*[![:space:]]}"}
    [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    val=${val#"${val%%[![:space:]]*}"}
    val=${val%"${val##*[![:space:]]}"}
    if [[ ${#val} -ge 2 && $val == \"*\" ]]; then
      val=${val:1:${#val}-2}
      val=${val//\\\"/\"}
      val=${val//\\\\/\\}
    elif [[ ${#val} -ge 2 && $val == \'*\' ]]; then
      val=${val:1:${#val}-2}
    fi
    export "$key=$val"
  done < "$f"
  return 0
}

# DynamicUser=: systemd makes the user known to the whole system (nss-systemd),
# so that `chown glance` in an ExecStartPre= and getpwuid() in the daemon
# work.  Without that, the user and its group are put in /etc/passwd and
# /etc/group when the service first starts, with ids from the range systemd
# uses for these (61184-65519).  The same name gets the same id (taken from
# the name, the next free one if that is in use).
dynamic_free_id() {
  local id n=0
  id=$(( 61184 + $(printf '%s' "$1" | cksum | cut -d' ' -f1) % 4336 ))
  while getent passwd "$id" > /dev/null || getent group "$id" > /dev/null; do
    id=$(( id + 1 ))
    (( id > 65519 )) && id=61184
    (( ++n > 4336 )) && return 1
  done
  printf '%s' "$id"
}

dynamic_user_ensure() {
  local name=$1 group=$2
  [[ $name =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ && $group =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || return 1
  if getent passwd "$name" > /dev/null && getent group "$group" > /dev/null; then return 0; fi
  [[ -w /etc/passwd && -w /etc/group ]] || return 1
  (
    flock -w 10 9 || exit 1
    local ent uid= gid= id
    # (again, now that nobody else is at it)
    if ent=$(getent passwd "$name"); then IFS=: read -r _ _ uid gid _ <<< "$ent"; fi
    if ent=$(getent group "$group"); then
      IFS=: read -r _ _ gid _ <<< "$ent"
    else
      # the group takes the user's id, if it has one and no group uses it
      id=$uid
      if [[ -z $id ]] || getent group "$id" > /dev/null; then id=$(dynamic_free_id "$group") || exit 1; fi
      printf '%s:x:%d:\n' "$group" "$id" >> /etc/group
      gid=$id
    fi
    if [[ -z $uid ]]; then
      id=$gid
      if getent passwd "$id" > /dev/null; then id=$(dynamic_free_id "$name") || exit 1; fi
      printf '%s:x:%d:%d:Dynamic user:/:/run/current-system/sw/bin/nologin\n' "$name" "$id" "$gid" >> /etc/passwd
    fi
  ) 9> /run/dynamic-users.lock
}

resolve_user() {
  # Sets u_uid, u_gid, u_groups (comma separated), u_home, u_shell, u_name.
  u_uid= u_gid= u_groups= u_home= u_shell= u_name=
  local ent g gid extra=()
  if (( ${U_DYNAMIC_USER-0} )) && [[ $scope != user ]]; then
    local dname=${U_USER:-${U_UNIT%.*}}
    [[ $dname =~ ^[0-9]+$ ]] || dynamic_user_ensure "$dname" "${U_GROUP:-$dname}" || true
  fi
  if [[ -n ${U_USER-} ]]; then
    if ent=$(getent passwd "$U_USER"); then
      IFS=: read -r u_name _ u_uid u_gid _ u_home u_shell <<< "$ent"
      u_groups=$(id -G "$u_name" 2>/dev/null)
      u_groups=${u_groups// /,}
    elif [[ $U_USER =~ ^[0-9]+$ ]]; then
      u_uid=$U_USER u_gid=$U_USER u_name=$U_USER u_home=/ u_shell=/bin/sh
    elif (( ${U_DYNAMIC_USER-0} )); then
      # No passwd entry: derive a stable id from the name, like systemd does.
      u_uid=$(( 61184 + $(printf '%s' "$U_USER" | cksum | cut -d' ' -f1) % 4336 ))
      u_gid=$u_uid u_name=$U_USER u_home=/ u_shell=/bin/sh
    else
      msg "unknown user '$U_USER'"
      return 1
    fi
  elif (( ${U_DYNAMIC_USER-0} )); then
    u_name=${U_UNIT%.*}
    if ent=$(getent passwd "$u_name"); then
      IFS=: read -r u_name _ u_uid u_gid _ u_home u_shell <<< "$ent"
    else
      u_uid=$(( 61184 + $(printf '%s' "$u_name" | cksum | cut -d' ' -f1) % 4336 ))
      u_gid=$u_uid u_home=/ u_shell=/bin/sh
    fi
  fi
  if [[ -n ${U_GROUP-} ]]; then
    if ent=$(getent group "$U_GROUP"); then
      IFS=: read -r _ _ u_gid _ <<< "$ent"
    elif [[ $U_GROUP =~ ^[0-9]+$ ]]; then
      u_gid=$U_GROUP
    elif (( ${U_DYNAMIC_USER-0} )); then
      # the group of a dynamic user is as dynamic as the user: same id from
      # the name, so that User=x Group=x is one pair
      u_gid=$(( 61184 + $(printf '%s' "$U_GROUP" | cksum | cut -d' ' -f1) % 4336 ))
    else
      msg "unknown group '$U_GROUP'"
      return 1
    fi
  fi
  for g in ${U_SUPP_GROUPS[@]+"${U_SUPP_GROUPS[@]}"}; do
    if ent=$(getent group "$g"); then
      IFS=: read -r _ _ gid _ <<< "$ent"
      extra+=("$gid")
    elif [[ $g =~ ^[0-9]+$ ]]; then
      extra+=("$g")
    else
      msg "unknown supplementary group '$g'"
      return 1
    fi
  done
  if (( ${#extra[@]} )); then
    local IFS=,
    u_groups=${u_groups:+$u_groups,}${extra[*]}
  fi
  return 0
}

prepare_env() {
  local v f
  export -n SHLVL PWD OLDPWD 2>/dev/null
  unset PATH
  if [[ -r /etc/locale.conf ]]; then load_env_file /etc/locale.conf; fi
  u_env
  if [[ $scope == user && -d $RT_STATE/.env ]]; then
    # what the session passed on with `systemctl --user import-environment`
    # and `dbus-update-activation-environment --systemd`
    set +f
    for f in "$RT_STATE"/.env/*; do
      [[ -f $f ]] && export "${f##*/}=$(< "$f")"
    done
    set -f
  fi
  for f in ${U_ENV_FILES[@]+"${U_ENV_FILES[@]}"}; do
    load_env_file "$f" || { PATH=$RT_PATH; return 1; }
  done
  for v in ${U_UNSET_ENV[@]+"${U_UNSET_ENV[@]}"}; do
    [[ $v == *=* ]] && v=${v%%=*}
    unset "$v" 2>/dev/null
  done
  u_path=${PATH-$RT_DEFAULT_PATH}
  export PATH=$RT_PATH
  resolve_user || return 1
  if [[ -n $u_name ]]; then
    # (what the unit says in Environment= wins, as with systemd: the module of
    # flaresolverr sets HOME for its dynamic user)
    export USER=${USER-$u_name} LOGNAME=${LOGNAME-$u_name} HOME=${HOME-${u_home:-/}} SHELL=${SHELL-${u_shell:-/bin/sh}}
  fi
  local __inv
  printf -v __inv '%016x' "$(( EPOCHSECONDS * 1000 + RANDOM ))"
  export INVOCATION_ID=${__u_spec_b:0:16}$__inv
  export SYSTEMD_EXEC_PID=$$
  return 0
}

make_dirs() {
  # make_dirs BASE MODE ENVVAR OWNED DIR...
  local base=$1 mode=$2 var=$3 owned=$4 d list=
  shift 4
  for d in "$@"; do
    mkdir -p "$base/$d" || return 1
    chmod "$mode" "$base/$d"
    if (( owned )) && [[ -n $u_uid ]]; then
      if [[ $(stat -c %u:%g "$base/$d") != "$u_uid:${u_gid:-0}" ]]; then
        chown -R "$u_uid:${u_gid:-0}" "$base/$d"
      fi
    fi
    list=${list:+$list:}$base/$d
  done
  [[ -n $list ]] && export "$var=$list"
  return 0
}

prepare_dirs() {
  make_dirs "$RT_DIR_RUNTIME" "${U_RUNTIME_DIR_MODE:-0755}" RUNTIME_DIRECTORY 1 ${U_RUNTIME_DIRS[@]+"${U_RUNTIME_DIRS[@]}"} || return 1
  make_dirs "$RT_DIR_STATE" "${U_STATE_DIR_MODE:-0755}" STATE_DIRECTORY 1 ${U_STATE_DIRS[@]+"${U_STATE_DIRS[@]}"} || return 1
  make_dirs "$RT_DIR_CACHE" "${U_CACHE_DIR_MODE:-0755}" CACHE_DIRECTORY 1 ${U_CACHE_DIRS[@]+"${U_CACHE_DIRS[@]}"} || return 1
  make_dirs "$RT_DIR_LOGS" "${U_LOGS_DIR_MODE:-0755}" LOGS_DIRECTORY 1 ${U_LOGS_DIRS[@]+"${U_LOGS_DIRS[@]}"} || return 1
  make_dirs "$RT_DIR_CONF" "${U_CONF_DIR_MODE:-0755}" CONFIGURATION_DIRECTORY 1 ${U_CONF_DIRS[@]+"${U_CONF_DIRS[@]}"} || return 1
}

# PrivateTmp=: the unit's /tmp and /var/tmp, where systemd puts them
# (/tmp/systemd-private-BOOTID-UNIT-XXXXXX/tmp: tests look for them there,
# and tmpfiles leaves them alone), made at the first command of a start and
# shared by the rest of it.  Prints a directory with links `tmp` and
# `var-tmp` to them, for unit-sandbox.
private_tmp() {
  local links=$sd/private-tmp base t
  if [[ -d $links/tmp/ && -d $links/var-tmp/ ]]; then
    printf '%s\n' "$links"
    return 0
  fi
  rm -rf "$links"
  mkdir -p "$links" || return 1
  for base in /tmp /var/tmp; do
    t=$(mktemp -d "$base/systemd-private-$__u_spec_b-$U_UNIT-XXXXXX") || return 1
    chmod 0700 "$t" && mkdir -m 1777 "$t/tmp" || return 1
    if [[ $base == /tmp ]]; then ln -s "$t/tmp" "$links/tmp"; else ln -s "$t/tmp" "$links/var-tmp"; fi
  done
  printf '%s\n' "$links"
}

remove_runtime_dirs() {
  local d l
  # PrivateTmp=: gone with the service
  for l in "$sd/private-tmp/tmp" "$sd/private-tmp/var-tmp"; do
    [[ -L $l ]] || continue
    d=$(readlink "$l")
    [[ $d == /tmp/systemd-private-* || $d == /var/tmp/systemd-private-* ]] && rm -rf "${d%/tmp}"
  done
  rm -rf "$sd/private-tmp"
  [[ ${U_RUNTIME_PRESERVE:-no} == no ]] || return 0
  for d in ${U_RUNTIME_DIRS[@]+"${U_RUNTIME_DIRS[@]}"}; do
    rm -rf "${RT_DIR_RUNTIME:?}/${d:?}"
  done
  return 0
}

prepare_creds() {
  local entry id src dir=$RT_CREDS/$U_UNIT f
  (( ${#U_CREDS[@]} + ${#U_SET_CREDS[@]} )) || return 0
  rm -rf "$dir"
  mkdir -p -m 0700 "$dir" || return 1
  for entry in ${U_SET_CREDS[@]+"${U_SET_CREDS[@]}"}; do
    id=${entry%%"$RT_SEP"*}
    printf '%s' "${entry#*"$RT_SEP"}" > "$dir/$id"
  done
  for entry in ${U_CREDS[@]+"${U_CREDS[@]}"}; do
    id=${entry%%"$RT_SEP"*} src=${entry#*"$RT_SEP"}
    [[ -n $src ]] || continue
    [[ $src == /* ]] || src=${RT_DIR_RUNTIME}/credstore/$src
    if [[ -d $src ]]; then
      set +f
      for f in "$src"/*; do [[ -f $f ]] && cp -- "$f" "$dir/${id}_${f##*/}"; done
      set -f
    elif [[ -r $src ]]; then
      cp -- "$src" "$dir/$id" || return 1
    else
      msg "cannot load credential $id from $src"
      return 1
    fi
  done
  chmod -R u=rX,go= "$dir"
  [[ -n $u_uid ]] && chown -R "$u_uid:${u_gid:-0}" "$dir"
  export CREDENTIALS_DIRECTORY=$dir
  return 0
}

remove_creds() { rm -rf "${RT_CREDS:?}/${U_UNIT:?}"; }

# While a service has the terminal that is the console (getty@tty1, with the
# console on tty0), systemd keeps its status lines off the console - they
# would land under a login prompt, in the middle of what is typed there.
# A service like that leaves a mark here while it runs, and rc.init stops
# copying the boot's progress to the console while there is one.
console_mark() {
  [[ $scope == system ]] || return 0
  # (a terminal of the unit's: its standard input or output, or a TTYPath=
  # given for a program that opens it itself, as agetty does)
  case ${U_STDIN:-null}/${U_STDOUT:-journal}/${U_STDERR:-inherit} in
    tty*/*/* | */tty/* | */*/tty) ;;
    *) [[ ${U_TTY:-/dev/console} != /dev/console ]] || return 0 ;;
  esac
  local tty=${U_TTY:-/dev/console} con act=()
  tty=${tty#/dev/}
  [[ -r /sys/class/tty/console/active ]] || return 0
  read -r -a act < /sys/class/tty/console/active
  (( ${#act[@]} )) || return 0
  con=${act[${#act[@]}-1]}
  [[ $con == tty0 && -r /sys/class/tty/tty0/active ]] && read -r con < /sys/class/tty/tty0/active
  [[ $tty == console || $tty == "$con" ]] || return 0
  mkdir -p "$RT_STATE/.on-console" && : > "$RT_STATE/.on-console/$U_UNIT"
}

open_stdio() {
  # Applies StandardInput=/Output=/Error= to the current (sub)shell.
  local tty=${U_TTY:-/dev/console}
  case ${U_STDIN:-null} in
    tty|tty-force|tty-fail) exec < "$tty" ;;
    file:*) exec < "${U_STDIN#file:}" ;;
    # an accepted connection (Accept=yes), which comes on descriptor 3
    socket) exec <&3 ;;
    *) exec < /dev/null ;;
  esac
  case ${U_STDOUT:-journal} in
    journal|inherit|socket)
      [[ ${U_STDIN:-null} == socket ]] && exec >&3 ;;
    null) exec > /dev/null ;;
    tty) exec > "$tty" ;;
    file:*) exec > "${U_STDOUT#file:}" ;;
    append:*) exec >> "${U_STDOUT#append:}" ;;
    truncate:*) exec > "${U_STDOUT#truncate:}" ;;
    kmsg|kmsg+console) exec > /dev/kmsg ;;
    *+console) ;;
    *) ;;
  esac
  case ${U_STDERR:-inherit} in
    socket) exec 2>&3 ;;
    null) exec 2> /dev/null ;;
    tty) exec 2> "$tty" ;;
    file:*) exec 2> "${U_STDERR#file:}" ;;
    append:*) exec 2>> "${U_STDERR#append:}" ;;
    truncate:*) exec 2> "${U_STDERR#truncate:}" ;;
    *) exec 2>&1 ;;
  esac
}

# child_setup PRIVILEGED: called in the process that is about to exec a unit
# command.  Sets pfx to the wrapper command line.
child_setup() {
  local privileged=$1
  pfx=()
  open_stdio
  [[ -n ${U_UMASK-} ]] && umask "$U_UMASK"
  if [[ -n ${U_OOM_ADJ-} ]]; then { echo "$U_OOM_ADJ" > /proc/self/oom_score_adj; } 2>/dev/null; fi
  # A command written with "+" is "executed with full privileges": as root,
  # without the unit's restrictions (see sandbox_prefix for what it keeps).
  local full=0
  [[ ${__u_flags-} == *+* ]] && full=1
  # RootDirectory=, which (RootDirectoryStartOnly=) may be for ExecStart= alone
  local rooted=0
  # (systemd 260 keeps RootDirectory= for "+" commands as well: only
  # RootDirectoryStartOnly= leaves the other commands out of it)
  if [[ -n ${U_ROOTDIR-} ]]; then
    rooted=1
    if (( ${U_ROOT_START_ONLY-0} )) && [[ ${__u_list-start} != start ]]; then rooted=0; fi
  fi
  if (( rooted )); then
    # the directory is one of the root's: unit-chroot goes there
    cd /
  elif [[ -n ${U_WORKDIR-} ]]; then
    local wd=$U_WORKDIR
    [[ $wd == "~" ]] && wd=${u_home:-/}
    if ! cd "$wd" 2>/dev/null; then
      if (( ! ${U_WORKDIR_OPTIONAL-0} )); then msg "cannot change to WorkingDirectory=$wd"; exit 200; fi
    fi
  else
    cd /
  fi
  # StandardInput=tty: the terminal becomes the controlling one of the
  # process, in a session of its own, as systemd makes it (ly dies without)
  case ${U_STDIN:-null} in
    tty|tty-force|tty-fail)
      local tty_args=()
      (( ${U_TTY_HANGUP-0} )) && tty_args+=(-h)
      (( ${U_TTY_RESET-0} )) && tty_args+=(-r)
      pfx+=("$(type -P unit-tty)" ${tty_args[@]+"${tty_args[@]}"} "${U_TTY:-/dev/console}")
      # and $TERM, which systemd gives a service on a terminal (termbox in
      # ly panics without it): linux on the virtual consoles, vt220 elsewhere
      # (unless the unit gave one; bash has a TERM=dumb of its own, unexported)
      if [[ ${TERM@a} != *x* ]]; then
        case ${U_TTY:-/dev/console} in
          /dev/console | /dev/tty[0-9]*) export TERM=linux ;;
          *) export TERM=vt220 ;;
        esac
      fi ;;
  esac
  [[ -n ${U_NICE-} ]] && pfx+=("$(type -P nice)" -n "$U_NICE")
  if [[ -n ${U_IOSCHED_CLASS-} ]]; then
    pfx+=("$(type -P ionice)" -c "$U_IOSCHED_CLASS")
    [[ -n ${U_IOSCHED_PRIO-} ]] && pfx+=(-n "$U_IOSCHED_PRIO")
  fi
  if [[ -n ${U_CPUSCHED_POLICY-} ]]; then
    # the priority within what the policy takes, as systemd clamps it: 1…99
    # for the real-time ones (so 1 when none is given), 0 for the others
    local prio=${U_CPUSCHED_PRIO:-0}
    case $U_CPUSCHED_POLICY in
      fifo | rr) (( prio < 1 )) && prio=1; (( prio > 99 )) && prio=99 ;;
      *) prio=0 ;;
    esac
    pfx+=("$(type -P chrt)" "--$U_CPUSCHED_POLICY" "$prio")
  fi
  [[ -n ${U_CPU_AFFINITY-} ]] && pfx+=("$(type -P taskset)" -c "${U_CPU_AFFINITY// /,}")
  (( ${#U_LIMITS[@]} )) && pfx+=("$(type -P prlimit)" "${U_LIMITS[@]}" --)
  # PAMName=: the main process runs in a PAM session (elogind's, with its
  # XDG_RUNTIME_DIR), opened as root before the sandbox and the change of
  # user, and closed when the process is gone (unit-pam stays for that)
  if [[ -n ${U_PAM_NAME-} && $scope == system && ${__u_list-start} == start ]]; then
    local pam_args=(-s "$U_PAM_NAME" -u "${u_name:-root}")
    case ${U_STDIN:-null}/${U_STDOUT:-journal} in
      tty*/* | */tty) pam_args+=(-t "${U_TTY:-/dev/console}") ;;
    esac
    pfx+=("$(type -P unit-pam)" "${pam_args[@]}" --)
  fi
  sandbox_prefix "$full"
  local sp=()
  if (( ! privileged )); then
    if [[ -n $u_uid ]]; then
      sp+=(--reuid "$u_uid" --regid "${u_gid:-$u_uid}")
      if [[ -n $u_groups ]]; then sp+=(--groups "$u_groups"); else sp+=(--clear-groups); fi
    elif [[ -n $u_gid ]]; then
      sp+=(--regid "$u_gid")
      if [[ -n $u_groups ]]; then sp+=(--groups "$u_groups"); else sp+=(--clear-groups); fi
    elif [[ -n $u_groups ]]; then
      sp+=(--groups "$u_groups")
    fi
    # RootDirectory= comes after setpriv (a root made of a closure, as with
    # confinement, has no setpriv in it), so unit-chroot needs
    # CAP_SYS_CHROOT for the moment it takes: as an ambient capability for a
    # user, and in the bounding set for root, which it then takes out of it
    # (-B; that needs CAP_SETPCAP, taken out last) when the unit's own
    # bounding set does not have it (gonic's is empty).
    local chroot_cap= bound=${U_CAP_BOUND-} chroot_drop=()
    if (( rooted )); then
      if [[ -n $u_uid && $u_uid != 0 ]]; then
        chroot_cap=+sys_chroot
        [[ -n $bound ]] && bound+=,+sys_chroot
      elif [[ $bound == -all* ]]; then
        [[ ,$bound, == *,+sys_chroot,* ]] || { bound+=,+sys_chroot; chroot_drop+=(-B sys_chroot); }
        [[ ,$bound, == *,+setpcap,* ]] || { bound+=,+setpcap; chroot_drop+=(-B setpcap); }
      fi
    fi
    [[ -n $bound ]] && sp+=(--bounding-set "$bound")
    if [[ -n ${U_CAP_AMBIENT-} ]]; then
      sp+=(--inh-caps "$U_CAP_AMBIENT${chroot_cap:+,$chroot_cap}" --ambient-caps "$U_CAP_AMBIENT${chroot_cap:+,$chroot_cap}")
    elif [[ -n $chroot_cap ]]; then
      sp+=(--inh-caps "$chroot_cap" --ambient-caps "$chroot_cap")
    elif [[ -n $u_uid && $u_uid != 0 ]]; then
      sp+=(--inh-caps=-all)
    fi
    (( ${U_NNP-0} )) && sp+=(--no-new-privs)
  fi
  (( ${#sp[@]} )) && pfx+=("$(type -P setpriv)" "${sp[@]}" --)
  if (( rooted )); then
    local keep=()
    # a unit that has CAP_SYS_CHROOT of its own, or runs as root, keeps it
    [[ -z $u_uid || $u_uid == 0 || ${U_CAP_AMBIENT-} == *sys_chroot* ]] && keep=(-k)
    [[ -n ${U_WORKDIR-} ]] && keep+=(-d "${U_WORKDIR#-}")
    pfx+=("$(type -P unit-chroot)" ${keep[@]+"${keep[@]}"} ${chroot_drop[@]+"${chroot_drop[@]}"} "$U_ROOTDIR" --)
  fi
  return 0
}

# PrivateTmp=, ProtectSystem=, …: the command starts in a mount namespace
# (and network, host name, IPC ones where asked) that unit-sandbox shapes
# before it drops privileges.  Appends to pfx.
# sandbox_prefix [FULL]: FULL (a "+" command) gets what systemd 260 still
# gives such a command (exec-invoke.c: needs_sandboxing false): the root
# directory, the bind mounts, ReadWritePaths=, TemporaryFileSystem= - not the
# private /tmp, /dev, network, the read-only and inaccessible paths, the
# protections of the system, the home directories and the kernel.
sandbox_prefix() {
  local full=${1:-0}
  (( ${#U_SANDBOX[@]} )) || return 0
  # (a user's own services have no way to make namespaces)
  [[ $scope == system ]] || return 0
  local a args=() ns=() skip=0 drop=0 kept=0
  for a in "${U_SANDBOX[@]}"; do
    if (( skip )); then
      # the value of a --root that does not apply to this command
      skip=0
      continue
    fi
    if (( drop )); then drop=0; continue; fi
    if (( full )); then
      case $a in
        --private-tmp|--protect-system|--protect-home|--read-only|--inaccessible) drop=1; continue ;;
        --private-devices|--kernel-tunables|--cgroups|--strict-run-writable|--private-network|--private-uts|--private-ipc|--loopback) continue ;;
        --root|--bind|--read-write|--tmpfs) kept=1 ;;
      esac
    fi
    case $a in
      --root)
        if (( ! rooted )); then skip=1; continue; fi
        args+=("$a") ;;
      --api-vfs)
        (( rooted )) && args+=("$a") ;;
      --private-network) ns+=(--net); args+=("$a") ;;
      --private-uts) ns+=(--uts) ;;
      --private-ipc) ns+=(--ipc) ;;
      --private-tmp)
        local dir
        dir=$(private_tmp) || { msg "cannot make the private /tmp"; exit 226; }
        args+=("$a" "$dir") ;;
      *) args+=("$a") ;;
    esac
  done
  # (a "+" command with nothing of the above runs as it is, outside)
  if (( full && ! kept )); then return 0; fi
  [[ " ${ns[*]-} " == *" --net "* ]] && args+=(--loopback)
  args+=(--stage "$sd")
  pfx+=("$(type -P unshare)" --mount --propagation private ${ns[@]+"${ns[@]}"} -- "$RT_SANDBOX" "${args[@]}" --)
}

# expand FUNCTION: evaluate one compiled command line with the unit's
# environment in place.  Sets __u_argv, __u_flags, __u_argv0.
expand() {
  local PATH=$u_path IFS=$' \t\n'
  __u_argv=() __u_flags= __u_argv0=
  "$1"
}

# run_cmd FUNCTION [FORCE_PRIVILEGED]: run one command and wait for it.
run_cmd() {
  local rc privileged=${2:-0}
  expand "$1"
  (( ${#__u_argv[@]} )) || return 0
  [[ $__u_flags == *+* ]] && privileged=1
  (
    child_setup "$privileged"
    export PATH=$u_path
    exec ${pfx[@]+"${pfx[@]}"} "${__u_argv[@]}"
  )
  rc=$?
  if (( rc != 0 )); then
    if [[ $__u_flags == *-* ]]; then
      return 0
    fi
    msg "command failed with status $rc: ${__u_argv[*]}"
  fi
  return $rc
}

# run_list NAME [FORCE_PRIVILEGED]: run every command of a list, stop at the
# first failure.
run_list() {
  local -n count="U_N_${1^^}"
  local i __u_list=$1
  for (( i = 0; i < ${count:-0}; i++ )); do
    run_cmd "u_${1}_$i" "${2:-0}" || return $?
  done
  return 0
}

# Like run_list, but keeps going (ExecStop=, ExecStopPost=).
run_list_all() {
  local -n count="U_N_${1^^}"
  local i rc=0 __u_list=$1
  for (( i = 0; i < ${count:-0}; i++ )); do
    run_cmd "u_${1}_$i" "${2:-0}" || rc=$?
  done
  return $rc
}

# (Whether ExecStartPre= and the like run with full privileges,
# PermissionsStartOnly=, is "$(( ${U_PERMISSIONS_START_ONLY:-0} ? 1 : 0 ))" where
# it is needed: an arithmetic expansion, as a $( ) would be a process.)

# s6-supervise hands us a pipe on fd RT_NFD; a newline on it means "ready".
notify_ready() {
  if [[ -e /proc/$BASHPID/fd/$RT_NFD ]]; then
    { echo >&"$RT_NFD"; } 2>/dev/null
    eval "exec $RT_NFD>&-"
  fi
  return 0
}

close_nfd() {
  [[ -e /proc/$BASHPID/fd/$RT_NFD ]] && eval "exec $RT_NFD>&-"
  return 0
}

# Sets fdchain to the command prefix that puts this unit's sockets on fd 3…
socket_chain() {
  fdchain=()
  local entry names= n=0 id
  for entry in ${U_SOCKETS[@]+"${U_SOCKETS[@]}"}; do
    id=${entry#*"$RT_SEP"}
    fdchain+=("$(type -P s6-fdholder-retrieve)" "$RT_FDHOLDER" "unit:$id" "$(type -P fdmove)" "$(( 3 + n ))" 0)
    names=${names:+$names:}${entry%%"$RT_SEP"*}
    n=$(( n + 1 ))
  done
  if (( n )); then
    fdchain+=("$(type -P redirfd)" -r 0 /dev/null)
    export LISTEN_FDS=$n LISTEN_PID=$$ LISTEN_FDNAMES=$names
  fi
  return 0
}

fail_start() {
  # Something went wrong before the main process was running.
  msg "start failed: $1"
  printf '%s\n' "$1" > "$sd/start-failed"
  # With a Restart= that covers this, the unit never is "failed": it goes
  # from activating to waiting for the restart.  (./finish applies the rest:
  # start limits, restart prevention.)
  case ${U_RESTART:-no} in
    always|on-failure) set_state activating auto-restart ;;
    *) set_state failed "$1" ;;
  esac
  exit 1
}

# --------------------------------------------------------------------------
# longrun: ./run

cmd_run() {
  exec 2>&1
  load "$1"
  rm -f "$sd/start-failed" "$sd/exit" "$sd/restart-requested"
  set_state activating

  if [[ -e $sd/restart-delay ]]; then
    local delay
    delay=$(< "$sd/restart-delay")
    rm -f "$sd/restart-delay"
    (( delay > 1000 )) && sleep "$(( (delay - 1000) / 1000 )).$(( (delay - 1000) % 1000 / 100 ))"
  fi
  printf '%s\n' "$EPOCHSECONDS" >> "$sd/starts"
  # the process group, for killing what the service leaves behind where
  # there is no control group to look in
  local stat pgrp
  stat=$(< /proc/$$/stat)
  stat=${stat##*) }
  read -r _ _ pgrp _ <<< "$stat"
  printf '%s\n' "$pgrp" > "$sd/pgid"

  if ! conditions U_ASSERTS; then
    fail_start "assertion failed ($__u_failed_condition)"
  fi
  if ! conditions U_CONDITIONS; then
    msg "skipped: condition not met ($__u_failed_condition)"
    set_state inactive condition
    notify_ready
    s6-svc -O . 2>/dev/null
    exit 0
  fi

  cgroup_enter
  prepare_env || fail_start environment
  prepare_dirs || fail_start directories
  prepare_creds || fail_start credentials
  fdchain=()

  local i rc
  for (( i = 0; i < ${U_N_CONDITION:-0}; i++ )); do
    run_cmd "u_condition_$i"; rc=$?
    if (( rc >= 1 && rc <= 254 )); then
      msg "skipped: ExecCondition= said no"
      set_state inactive condition
      notify_ready
      s6-svc -O . 2>/dev/null
      exit 0
    elif (( rc == 255 )); then
      fail_start exec-condition
    fi
  done

  run_list start_pre "$(( ${U_PERMISSIONS_START_ONLY:-0} ? 1 : 0 ))" || fail_start start-pre

  if [[ $U_TYPE == forking ]]; then
    run_forking
    return
  fi

  if (( ${U_N_START:-0} == 0 )); then fail_start "no ExecStart="; fi
  socket_chain
  expand "u_start_$(( U_N_START - 1 ))"
  (( ${#__u_argv[@]} )) || fail_start "empty ExecStart="
  local privileged=0
  [[ $__u_flags == *+* ]] && privileged=1

  local need_watcher=0 ready_fifo=
  (( ${U_N_START_POST:-0} )) && need_watcher=1
  [[ $U_TYPE == dbus && -n ${U_BUSNAME-} ]] && need_watcher=1

  if [[ -n ${U_NOTIFY_FD-} ]]; then
    # The daemon speaks the s6 readiness protocol itself: give it the pipe.
    eval "exec $U_NOTIFY_FD>&$RT_NFD"
    close_nfd
    set_state active
    need_watcher=0
    if (( ${U_N_START_POST:-0} )); then
      ( ( export MAINPID=$$; unset LISTEN_FDS LISTEN_PID LISTEN_FDNAMES; fdchain=()
          eval "exec $U_NOTIFY_FD>&-"
          run_list start_post "$(( ${U_PERMISSIONS_START_ONLY:-0} ? 1 : 0 ))" ) & )
    fi
  fi

  case $U_TYPE in
    notify|notify-reload)
      rm -f "$sd/notify"
      export NOTIFY_SOCKET=$sd/notify
      # daemons that change user themselves have to be able to reach it
      # (a user's own services run as the user, so theirs stays private)
      notify_open=
      [[ $scope == system ]] && notify_open=-w
      # a notify-reload daemon reports each reload as well (RELOADING=1, then
      # READY=1) and looks for the socket first (sshd logs an error if it is
      # gone), so the socket stays for as long as the service runs
      notify_keep=
      [[ $U_TYPE == notify-reload ]] && notify_keep=-k
      if (( need_watcher )); then
        ready_fifo=$sd/ready
        rm -f "$ready_fifo"
        mkfifo -m 0600 "$ready_fifo"
        exec {rfd}<> "$ready_fifo"
        unit-notify -s "$sd/notify" -p $$ ${u_uid:+-u "$u_uid"} $notify_open $notify_keep >&"$rfd" || fail_start notify-socket
      else
        unit-notify -s "$sd/notify" -p $$ ${u_uid:+-u "$u_uid"} $notify_open $notify_keep >&"$RT_NFD" || fail_start notify-socket
        close_nfd
      fi ;;
  esac

  if (( need_watcher )); then
    # Runs beside the main process: waits until it is really up, runs
    # ExecStartPost=, then tells s6 the service is ready.  Double fork, so
    # that the daemon does not inherit a child it knows nothing about.
    (
      (
        main=$$
        alive() { kill -0 "$main" 2>/dev/null; }
        case $U_TYPE in
          notify|notify-reload)
            until read -r -t 1 -u "$rfd" _; do alive || exit 0; done ;;
          dbus)
            # (a user's service takes its name on the user's session bus)
            local bus=--system
            [[ $scope == user ]] && bus=--bus=${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR:-/run/user/$UID}/bus}
            until dbus-send "$bus" --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus \
                org.freedesktop.DBus.NameHasOwner "string:$U_BUSNAME" 2>/dev/null | grep -q 'boolean true'; do
              alive || exit 0
              sleep 0.2
            done ;;
        esac
        [[ -n $ready_fifo ]] && { exec {rfd}>&-; rm -f "$ready_fifo"; }
        unset LISTEN_FDS LISTEN_PID LISTEN_FDNAMES NOTIFY_SOCKET
        fdchain=()
        export MAINPID=$main
        if ! run_list start_post "$(( ${U_PERMISSIONS_START_ONLY:-0} ? 1 : 0 ))"; then
          printf 'start-post\n' > "$sd/start-failed"
          kill -s "${U_KILL_SIGNAL:-TERM}" "$main" 2>/dev/null
          exit 0
        fi
        alive || exit 0
        if [[ -e $sd/restart-requested ]]; then
          # `systemctl restart` from this unit's own start (an ExecStartPost=
          # that restarts what it belongs to): the start is done, so the
          # restart is next.  ./finish sees the request and starts it again.
          kill -s "${U_KILL_SIGNAL:-TERM}" "$main" 2>/dev/null
          exit 0
        fi
        set_state active
        notify_ready
      ) &
    )
    [[ -n $ready_fifo ]] && exec {rfd}>&-
    close_nfd
  elif [[ -n ${U_NOTIFY_FD-} ]]; then
    :
  elif [[ $U_TYPE != notify && $U_TYPE != notify-reload ]]; then
    set_state active
    notify_ready
  else
    set_state active
  fi

  # Type=idle: as with systemd, the program waits until the boot's jobs are
  # done (five seconds at most), so that a getty's prompt does not come out
  # in the middle of what the boot writes to the console.  (s6-rc has been
  # told the service is up: the boot does not wait for this.)
  if [[ $U_TYPE == idle && $scope == system ]]; then
    local i
    for (( i = 0; i < 50; i++ )); do
      [[ -e $RT_STATE/.booting ]] || break
      sleep 0.1
    done
  fi

  # X-WaitForVT=: the program is for whoever switches to that console (a
  # getty of tty2 and up, which logind would start only then): until it is on
  # the screen, the service waits here, up as far as s6-rc is concerned.
  if (( ${U_VT_WAIT:-0} )); then
    unit-vt-wait "${U_TTY:-/dev/console}"
  fi

  console_mark
  child_setup "$privileged"
  export PATH=$u_path
  if [[ -n $__u_argv0 && ${#pfx[@]} -eq 0 && ${#fdchain[@]} -eq 0 ]]; then
    exec -a "$__u_argv0" "${__u_argv[@]}"
  fi
  exec ${fdchain[@]+"${fdchain[@]}"} ${pfx[@]+"${pfx[@]}"} "${__u_argv[@]}"
  exit 203
}

# Type=forking: the command daemonises, so nothing is left for s6-supervise to
# watch.  This shell stays in its place: it finds the daemon, forwards
# signals to it and exits when it does.
run_forking() {
  local pid= i
  run_list start || fail_start start
  if [[ -n ${U_PIDFILE-} ]]; then
    for (( i = 0; i < 100; i++ )); do
      if [[ -s $U_PIDFILE ]]; then pid=$(< "$U_PIDFILE"); pid=${pid//[^0-9]/}; fi
      [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null && break
      pid=
      sleep 0.1
    done
  fi
  if [[ -z $pid && -r $cg/cgroup.procs ]]; then
    for i in $(< "$cg/cgroup.procs"); do
      [[ $i != $$ ]] && { pid=$i; break; }
    done
  fi
  [[ -n $pid ]] || fail_start "daemon exited right after forking"
  printf '%s\n' "$pid" > "$sd/mainpid"
  export MAINPID=$pid
  if ! run_list start_post "$(( ${U_PERMISSIONS_START_ONLY:-0} ? 1 : 0 ))"; then
    kill -s "${U_KILL_SIGNAL:-TERM}" "$pid" 2>/dev/null
    fail_start start-post
  fi
  if [[ -e $sd/restart-requested ]]; then
    # asked for during the start: see the watcher in cmd_run
    kill -s "${U_KILL_SIGNAL:-TERM}" "$pid" 2>/dev/null
    exit 0
  fi
  set_state active
  notify_ready
  local sig
  for sig in TERM HUP INT QUIT USR1 USR2; do
    # shellcheck disable=SC2064
    trap "kill -s $sig $pid 2>/dev/null" "$sig"
  done
  while kill -0 "$pid" 2>/dev/null; do
    tail --pid="$pid" -f /dev/null &
    wait $! 2>/dev/null
  done
  exit 0
}

# --------------------------------------------------------------------------
# longrun: ./finish

in_list() {
  local needle=$1 x
  shift
  for x in "$@"; do [[ $x == "$needle" ]] && return 0; done
  return 1
}

cmd_finish() {
  exec 2>&1
  load "$1"
  local code=${2:-0} signum=${3:-0} signame= clean=0 result=success wanted
  if (( code == 256 )); then
    signame=$(kill -l "$signum" 2>/dev/null) || signame=$signum
    if in_list "$signame" HUP INT TERM PIPE ${U_SUCCESS_SIGNALS[@]+"${U_SUCCESS_SIGNALS[@]}"}; then
      clean=1
    else
      result=signal
    fi
    export EXIT_CODE=killed EXIT_STATUS=$signame
  else
    if in_list "$code" ${U_SUCCESS_CODES[@]+"${U_SUCCESS_CODES[@]}"}; then clean=1; else result=exit-code; fi
    export EXIT_CODE=exited EXIT_STATUS=$code
  fi
  if [[ -e $sd/start-failed ]]; then
    result=$(< "$sd/start-failed")
    clean=0
  fi
  # asked for by the unit's own processes: see systemctl's restart
  local requested=0
  if [[ -e $sd/restart-requested ]]; then
    requested=1
    rm -f "$sd/restart-requested"
  fi
  wanted=$(s6-svstat -o wantedup . 2>/dev/null) || wanted=true
  printf '%s %s %s\n' "$code" "$signum" "$result" > "$sd/exit"

  if [[ $(< "$sd/state") != inactive || ! -e $sd/result || $(< "$sd/result") != condition ]]; then
    if prepare_env; then
      export SERVICE_RESULT=$result
      run_list_all stop_post "$(( ${U_PERMISSIONS_START_ONLY:-0} ? 1 : 0 ))"
    fi
    # (the empty control group stays until it is known whether the service
    # is started again: creating it anew is a process more on the way)
    cgroup_kill 5 keep
    remove_runtime_dirs
    remove_creds
    rm -f "$RT_STATE/.on-console/$U_UNIT"
    rm -f "$sd/notify" "$sd/ready" "$sd/mainpid"
  else
    exit 0
  fi

  if [[ $wanted != true ]]; then
    rmdir "$cg" 2>/dev/null
    set_state inactive "$result"
    exit 0
  fi

  # The service went away on its own: apply Restart=.
  local restart=0
  case ${U_RESTART:-no} in
    always) restart=1 ;;
    on-success) (( clean )) && restart=1 ;;
    on-failure) (( clean )) || restart=1 ;;
    on-abnormal|on-abort) [[ $result == signal ]] && restart=1 ;;
  esac
  if (( code != 256 )); then
    in_list "$code" ${U_PREVENT_CODES[@]+"${U_PREVENT_CODES[@]}"} && restart=0
    in_list "$code" ${U_FORCE_CODES[@]+"${U_FORCE_CODES[@]}"} && restart=1
  else
    in_list "$signame" ${U_PREVENT_SIGNALS[@]+"${U_PREVENT_SIGNALS[@]}"} && restart=0
    in_list "$signame" ${U_FORCE_SIGNALS[@]+"${U_FORCE_SIGNALS[@]}"} && restart=1
  fi

  (( requested )) && restart=1

  if (( restart )) && (( ${U_START_LIMIT_INTERVAL_MS:-0} > 0 && ${U_START_LIMIT_BURST:-0} > 0 )); then
    local t n=0 since=$(( EPOCHSECONDS - U_START_LIMIT_INTERVAL_MS / 1000 )) keep=()
    if [[ -r $sd/starts ]]; then
      while read -r t; do
        if (( t >= since )); then n=$(( n + 1 )); keep+=("$t"); fi
      done < "$sd/starts"
      : > "$sd/starts"
      (( ${#keep[@]} )) && printf '%s\n' "${keep[@]}" > "$sd/starts"
    fi
    if (( n >= U_START_LIMIT_BURST )); then
      msg "start request repeated too quickly, giving up"
      result=start-limit-hit
      restart=0
    fi
  fi

  if (( restart )); then
    msg "main process exited ($EXIT_CODE/$EXIT_STATUS), restarting"
    # (systemctl show -p NRestarts)
    local nr=0
    [[ -r $sd/nrestarts ]] && nr=$(< "$sd/nrestarts")
    printf '%s\n' "$(( nr + 1 ))" > "$sd/nrestarts"
    # (already so, if it was the start that failed)
    local cur_state= cur_result=
    [[ -r $sd/state ]] && cur_state=$(< "$sd/state")
    [[ -r $sd/result ]] && cur_result=$(< "$sd/result")
    if [[ $cur_state != activating || $cur_result != auto-restart ]]; then
      set_state activating auto-restart
    fi
    # (RestartSec= is for the service's own failures, not for being asked)
    if (( requested )); then printf '0\n' > "$sd/restart-delay"; else printf '%s\n' "${U_RESTART_MS:-100}" > "$sd/restart-delay"; fi
    exit 0
  fi
  if (( clean )) && [[ $result == success ]]; then
    if (( ${U_REMAIN:-0} )); then set_state active exited; else set_state inactive success; fi
  else
    msg "failed ($result: $EXIT_CODE/$EXIT_STATUS)"
    set_state failed "$result"
  fi
  rm -f "$sd/starts"
  rmdir "$cg" 2>/dev/null
  # 125: tell s6-supervise not to start it again.
  exit 125
}

# --------------------------------------------------------------------------
# oneshots and jobs

# Send our output to the unit's log directory as well as to whoever started us.
log_open() {
  local d=$RT_LOGDIR/$U_ATOM
  __u_logpid=
  # What goes to the console (our own stdout, the boot log) stays the
  # failures; the output of the command is for the unit's log, as for
  # systemd, where it is the journal and not the screen.
  exec {__u_console}>&1
  if mkdir -p "$d" 2>/dev/null; then
    # shellcheck disable=SC2086
    exec > >(exec s6-log -b -- $RT_LOGSCRIPT "$d") 2>&1
    __u_logpid=$!
  else
    exec 2>&1
  fi
}

log_close() {
  if [[ -n ${__u_logpid-} ]]; then
    exec >&- 2>&-
    wait "$__u_logpid" 2>/dev/null
    __u_logpid=
  fi
}

# A line for the console (and the boot log) about something that failed.
console_note() {
  [[ -n ${__u_console-} ]] || return 0
  printf '%s: %s\n' "$U_UNIT" "$*" >&"$__u_console" 2>/dev/null || true
}

# The start sequence of a service that runs to completion.
oneshot_start() {
  if ! conditions U_ASSERTS; then
    msg "assertion failed ($__u_failed_condition)"
    set_state failed assert
    return 1
  fi
  if ! conditions U_CONDITIONS; then
    msg "skipped: condition not met ($__u_failed_condition)"
    set_state inactive condition
    return 0
  fi
  set_state activating
  cgroup_enter
  local rc=0 i
  if ! prepare_env; then set_state failed environment; cgroup_leave; return 1; fi
  if ! prepare_dirs || ! prepare_creds; then set_state failed resources; cgroup_leave; return 1; fi
  fdchain=()
  for (( i = 0; i < ${U_N_CONDITION:-0}; i++ )); do
    run_cmd "u_condition_$i"; rc=$?
    if (( rc >= 1 && rc <= 254 )); then
      msg "skipped: ExecCondition= said no"
      set_state inactive condition
      cgroup_leave
      return 0
    elif (( rc == 255 )); then
      set_state failed exec-condition
      cgroup_leave
      return 1
    fi
  done
  rc=0
  run_list start_pre "$(( ${U_PERMISSIONS_START_ONLY:-0} ? 1 : 0 ))" || rc=$?
  (( rc == 0 )) && { run_list start || rc=$?; }
  (( rc == 0 )) && { run_list start_post "$(( ${U_PERMISSIONS_START_ONLY:-0} ? 1 : 0 ))" || rc=$?; }
  if (( rc != 0 )) && in_list "$rc" ${U_SUCCESS_CODES[@]+"${U_SUCCESS_CODES[@]}"}; then rc=0; fi
  cgroup_leave
  if (( rc != 0 )); then
    export SERVICE_RESULT=exit-code EXIT_CODE=exited EXIT_STATUS=$rc
    run_list_all stop_post "$(( ${U_PERMISSIONS_START_ONLY:-0} ? 1 : 0 ))"
    cgroup_kill 2
    remove_runtime_dirs
    remove_creds
    set_state failed exit-code
    return "$rc"
  fi
  if (( ${U_REMAIN:-0} )); then
    set_state active exited
  else
    export SERVICE_RESULT=success EXIT_CODE=exited EXIT_STATUS=0
    run_list_all stop "$(( ${U_PERMISSIONS_START_ONLY:-0} ? 1 : 0 ))"
    run_list_all stop_post "$(( ${U_PERMISSIONS_START_ONLY:-0} ? 1 : 0 ))"
    cgroup_kill 2
    remove_runtime_dirs
    remove_creds
    set_state inactive success
  fi
  return 0
}

cmd_up() {
  load "$1"
  log_open
  local rc=0
  oneshot_start || rc=$?
  if (( rc != 0 )); then
    console_note "FAILED (status $rc); the output is in /var/log/s6/$U_ATOM"
    if (( ${U_HARD_FAIL:-0} )); then
      msg "FAILED (status $rc)"
    else
      msg "FAILED (status $rc); nothing requires this unit, carrying on"
      rc=0
    fi
  fi
  log_close
  exit "$rc"
}

cmd_down() {
  load "$1"
  log_open
  if [[ -r $sd/state && $(< "$sd/state") == active ]]; then
    if prepare_env; then
      export SERVICE_RESULT=success EXIT_CODE=exited EXIT_STATUS=0
      run_list_all stop "$(( ${U_PERMISSIONS_START_ONLY:-0} ? 1 : 0 ))"
      run_list_all stop_post "$(( ${U_PERMISSIONS_START_ONLY:-0} ? 1 : 0 ))"
    fi
  fi
  cgroup_kill 5
  remove_runtime_dirs
  remove_creds
  set_state inactive success
  log_close
  exit 0
}

# Run a service once, to completion, without touching s6-rc's idea of it.
cmd_job() {
  load "$1"
  if [[ $U_TYPE != oneshot && ${U_KIND-service} == service ]] && [[ -n ${U_ATOM-} ]]; then
    # A service that stays up (what a timer or a path unit points at, as
    # keepalived's boot delay does): the trigger starts it like
    # `systemctl start`, with what it needs; it is not run to completion here.
    local live=/run/s6-rc
    [[ $scope == user ]] && live=${UNIT_USER_STATE:-$XDG_RUNTIME_DIR}/s6-rc
    s6-rc -l "$live" -b -u change "$U_ATOM" || true
    # (up as far as s6-rc knows, but it ran to completion, failed, or was
    # stopped by hand: again)
    if ! s6-svstat -o up "$RT_SCANDIR/$U_ATOM" 2>/dev/null | grep -q true; then
      [[ -d $RT_SCANDIR/$U_ATOM-log ]] && s6-svc -u "$RT_SCANDIR/$U_ATOM-log"
      rm -f "$sd/starts"
      s6-svc -u "$RT_SCANDIR/$U_ATOM"
    fi
    exit 0
  fi
  exec {lockfd}> "$sd/job.lock"
  if ! flock -n "$lockfd"; then
    msg "still running, not starting it again"
    exit 0
  fi
  if [[ $U_TYPE != oneshot ]] && s6-svstat -o up "$RT_SCANDIR/$U_ATOM" 2>/dev/null | grep -q true; then
    msg "already active"
    exit 0
  fi
  log_open
  local rc=0
  oneshot_start || rc=$?
  cgroup_kill 2
  log_close
  exit "$rc"
}

cmd_stop_hook() {
  load "$1"
  exec 2>&1
  local pid
  pid=$(s6-svstat -o pid "$RT_SCANDIR/$U_ATOM" 2>/dev/null) || pid=
  [[ -r $sd/mainpid ]] && pid=$(< "$sd/mainpid")
  [[ $pid == -1 ]] && pid=
  [[ -n $pid ]] || exit 0
  prepare_env || exit 0
  export MAINPID=$pid
  run_list_all stop "$(( ${U_PERMISSIONS_START_ONLY:-0} ? 1 : 0 ))"
  exit 0
}

cmd_reload() {
  load "$1"
  local pid
  pid=$(s6-svstat -o pid "$RT_SCANDIR/$U_ATOM" 2>/dev/null) || pid=
  [[ -r $sd/mainpid ]] && pid=$(< "$sd/mainpid")
  [[ $pid == -1 ]] && pid=
  if (( ${U_N_RELOAD:-0} == 0 )); then
    if [[ -n ${U_RELOAD_SIGNAL-} && -n $pid ]]; then
      jlog "Reloading ${U_DESCRIPTION:-$U_UNIT}..."
      kill -s "$U_RELOAD_SIGNAL" "$pid"
      local rc=$?
      (( rc == 0 )) && jlog "Reloaded ${U_DESCRIPTION:-$U_UNIT}."
      exit "$rc"
    fi
    msg "no ExecReload= defined"
    exit 1
  fi
  prepare_env || exit 1
  export MAINPID=$pid
  jlog "Reloading ${U_DESCRIPTION:-$U_UNIT}..."
  local rc=0
  run_list reload || rc=$?
  (( rc == 0 )) && jlog "Reloaded ${U_DESCRIPTION:-$U_UNIT}."
  exit "$rc"
}

# --------------------------------------------------------------------------
# mounts, swap, devices

cmd_mount_up() {
  load "$1"
  log_open
  local rc=0 args=()
  if ! conditions U_CONDITIONS; then
    msg "skipped: condition not met ($__u_failed_condition)"
  elif mountpoint -q "$U_WHERE" 2>/dev/null; then
    set_state active mounted
  else
    mkdir -p -m "${U_DIR_MODE:-0755}" "$U_WHERE"
    # as systemd does, a bind mount creates its source too (prowlarr's dataDir)
    if [[ ,$U_OPTIONS, == *,bind,* || ,$U_OPTIONS, == *,rbind,* || $U_FSTYPE == bind || $U_FSTYPE == rbind ]] &&
      [[ $U_WHAT == /* && ! -e $U_WHAT ]]; then
      mkdir -p -m "${U_DIR_MODE:-0755}" "$U_WHAT"
    fi
    [[ -n $U_FSTYPE ]] && args+=(-t "$U_FSTYPE")
    [[ -n $U_OPTIONS ]] && args+=(-o "$U_OPTIONS")
    # fsck.* and mount.* helpers come with the system profile
    PATH=$PATH:$RT_DEFAULT_PATH
    if (( ${U_FSCK:-0} )) && [[ -b $U_WHAT ]]; then
      fsck -a -T ${U_FSTYPE:+-t "$U_FSTYPE"} "$U_WHAT"
      rc=$?
      # 0: clean, 1: errors corrected; anything else is left to the mount to judge
      (( rc > 1 )) && msg "fsck on $U_WHAT returned $rc"
      rc=0
    fi
    if mount "${args[@]}" "$U_WHAT" "$U_WHERE"; then
      set_state active mounted
    else
      rc=$?
      set_state failed exit-code
      if (( ${U_HARD_FAIL:-0} )); then
        msg "FAILED to mount $U_WHAT on $U_WHERE"
      else
        msg "FAILED to mount $U_WHAT on $U_WHERE; nothing requires it, carrying on"
        rc=0
      fi
    fi
  fi
  log_close
  exit "$rc"
}

cmd_mount_down() {
  load "$1"
  local args=()
  (( ${U_LAZY_UNMOUNT:-0} )) && args+=(-l)
  (( ${U_FORCE_UNMOUNT:-0} )) && args+=(-f)
  if mountpoint -q "$U_WHERE" 2>/dev/null; then
    umount "${args[@]}" "$U_WHERE" || msg "cannot unmount $U_WHERE"
  fi
  set_state inactive success
  exit 0
}

cmd_swap_up() {
  load "$1"
  local rc=0 args=()
  [[ -n $U_PRIORITY ]] && args+=(-p "$U_PRIORITY")
  [[ -n $U_OPTIONS ]] && args+=(-o "$U_OPTIONS")
  if grep -q "^$(readlink -f "$U_WHAT") " /proc/swaps 2>/dev/null; then
    set_state active
  elif swapon "${args[@]}" "$U_WHAT"; then
    set_state active
  else
    rc=$?
    set_state failed exit-code
    (( ${U_HARD_FAIL:-0} )) || rc=0
    msg "FAILED to enable swap on $U_WHAT"
  fi
  exit "$rc"
}

cmd_swap_down() {
  load "$1"
  swapoff "$U_WHAT" 2>/dev/null
  set_state inactive success
  exit 0
}

cmd_device() {
  U_UNIT=$1
  local path=$2 timeout=$3 hard=$4 waited=0
  # /sys/subsystem/net/devices/X is how systemd spells /sys/class/net/X
  path=${path/#\/sys\/subsystem\/net\/devices\//\/sys\/class\/net\/}
  if (( timeout < 0 )); then
    # a device that only triggers other units: it is there or it is not
    [[ -e $path ]] && exit 0
    msg "not present"
    exit 1
  fi
  while [[ ! -e $path ]]; do
    if (( timeout > 0 && waited >= timeout )); then
      if (( hard )); then
        msg "timed out waiting for $path"
        exit 1
      fi
      msg "timed out waiting for $path; nothing requires it, carrying on"
      exit 0
    fi
    sleep 0.2
    waited=$(( waited + 200 ))
  done
  exit 0
}

# --------------------------------------------------------------------------
# sockets: bound here, kept in the fd holder, handed to the service when it
# starts.  The service can restart without the socket ever going away.

cmd_socket_up() {
  load "$1"
  log_open
  local rc=0 i=0 entry kind addr args link
  if ! conditions U_CONDITIONS; then
    msg "skipped: condition not met ($__u_failed_condition)"
    log_close
    exit 0
  fi
  if prepare_env; then
    fdchain=()
    run_list start_pre 1 || rc=$?
  else
    rc=1
  fi
  if (( rc == 0 )); then
    for entry in ${U_LISTEN[@]+"${U_LISTEN[@]}"}; do
      kind=${entry%%"$RT_SEP"*} addr=${entry#*"$RT_SEP"}
      args=(--"$kind" "$addr" --mode "${U_SOCKET_MODE:-0666}" --dir-mode "${U_SOCKET_DIR_MODE:-0755}")
      [[ -n ${U_SOCKET_USER-} ]] && args+=(--user "$U_SOCKET_USER")
      [[ -n ${U_SOCKET_GROUP-} ]] && args+=(--group "$U_SOCKET_GROUP")
      [[ -n ${U_BACKLOG-} ]] && args+=(--backlog "$U_BACKLOG")
      [[ ${U_BIND_IPV6_ONLY:-default} != default ]] && args+=(--ipv6-only "$U_BIND_IPV6_ONLY")
      (( ${U_REUSE_PORT:-0} )) && args+=(--reuse-port)
      (( ${U_FREE_BIND:-0} )) && args+=(--free-bind)
      (( ${U_PASS_CRED:-0} )) && args+=(--pass-cred)
      s6-fdholder-delete "$RT_FDHOLDER" "unit:$U_UNIT:$i" 2>/dev/null
      if ! unit-socket "${args[@]}" -- s6-fdholder-store "$RT_FDHOLDER" "unit:$U_UNIT:$i"; then
        msg "cannot set up $kind socket $addr"
        rc=1
        break
      fi
      i=$(( i + 1 ))
    done
  fi
  if (( rc == 0 )); then
    for link in ${U_SYMLINKS[@]+"${U_SYMLINKS[@]}"}; do
      entry=${U_LISTEN[0]#*"$RT_SEP"}
      mkdir -p "${link%/*}"
      ln -sfn "$entry" "$link"
    done
    run_list start_post 1 || rc=$?
  fi
  if (( rc == 0 )); then
    # A restart of the socket alone (systemctl restart X.socket) gives new
    # sockets, while what waits on them for the service (the -activate atom,
    # cmd_socket_activate) still holds the old ones: whatever came on the new
    # ones queued up and the service was never started.  It takes them again.
    if [[ -d $RT_SCANDIR/$U_ATOM-activate ]] &&
        [[ $(s6-svstat -o up "$RT_SCANDIR/$U_ATOM-activate" 2>/dev/null) == true ]]; then
      s6-svc -K "$RT_SCANDIR/$U_ATOM-activate"
    fi
    set_state active listening
  else
    set_state failed resources
    if (( ! ${U_HARD_FAIL:-0} )); then
      msg "FAILED; nothing requires this unit, carrying on"
      rc=0
    fi
  fi
  log_close
  exit "$rc"
}

cmd_socket_down() {
  load "$1"
  local i=0 entry kind addr
  if prepare_env; then run_list_all stop_pre 1; fi
  for entry in ${U_LISTEN[@]+"${U_LISTEN[@]}"}; do
    kind=${entry%%"$RT_SEP"*} addr=${entry#*"$RT_SEP"}
    s6-fdholder-delete "$RT_FDHOLDER" "unit:$U_UNIT:$i" 2>/dev/null
    if (( ${U_REMOVE_ON_STOP:-0} )) && [[ $addr == /* ]]; then rm -f "$addr"; fi
    i=$(( i + 1 ))
  done
  if (( ${U_REMOVE_ON_STOP:-0} )); then
    for entry in ${U_SYMLINKS[@]+"${U_SYMLINKS[@]}"}; do rm -f "$entry"; done
  fi
  [[ ${u_path+set} ]] && run_list_all stop_post 1
  set_state inactive success
  exit 0
}

# --------------------------------------------------------------------------
# devices: start units when the hardware they belong to appears, which is
# what systemd does for units wanted by a .device unit and for the
# SYSTEMD_WANTS property set by udev rules (bluetooth.target, sound.target…).

cmd_device_watch() {
  U_UNIT=device-watch
  local db=$1 path units line key val
  local -A wants=() handled=()
  local pending=()
  if [[ -r $db/devices.tsv ]]; then
    while IFS=$'\t' read -r path units; do wants[$path]=$units; done < "$db/devices.tsv"
  fi

  start_units() {
    # idempotent: units that are already active are left alone
    PATH=$PATH:$RT_DEFAULT_PATH systemctl start --no-block "$@" 2>&1
  }

  local devpath= devname= devlinks= iface= subsystem= sdwants= action= usec=
  finish_event() {
    local found=() l
    if [[ -n $devpath ]]; then
      if [[ $action == remove ]]; then
        unset "handled[$devpath]"
      elif [[ -z ${handled[$devpath]-} ]]; then
        handled[$devpath]=1
        [[ -n ${wants[/sys$devpath]-} ]] && found+=(${wants[/sys$devpath]})
        [[ -n $devname && -n ${wants[$devname]-} ]] && found+=(${wants[$devname]})
        for l in $devlinks; do [[ -n ${wants[$l]-} ]] && found+=(${wants[$l]}); done
        [[ $subsystem == net && -n $iface && -n ${wants[net:$iface]-} ]] && found+=(${wants[net:$iface]})
        found+=($sdwants)
        if [[ -n $usec && ${#found[@]} -gt 0 ]]; then
          # What a device wants is started when the device appears, as with
          # systemd.  A unit that someone has started, stopped or seen fail
          # since then is left as they left it: on a busy machine the event
          # (or the look at what is there) can come seconds late.
          local u kept=() up appeared
          read -r up _ < /proc/uptime
          appeared=$(( EPOCHSECONDS - ${up%.*} + usec / 1000000 ))
          for u in "${found[@]}"; do
            if [[ -r $RT_STATE/$u/state ]] && (( $(stat -c %Y "$RT_STATE/$u/state") > appeared )); then
              continue
            fi
            kept+=("$u")
          done
          found=(${kept[@]+"${kept[@]}"})
        fi
        if (( ${#found[@]} )); then
          if [[ -e $RT_STATE/.booting ]]; then
            pending+=("${found[@]}")
          else
            if (( scanning )); then
              msg "${devname:-$devpath} (there already): starting ${found[*]}"
            else
              msg "${devname:-$devpath} (${action:-event}): starting ${found[*]}"
            fi
            start_units "${found[@]}"
          fi
        fi
      fi
    fi
    devpath= devname= devlinks= iface= subsystem= sdwants= action= usec=
  }

  property() {
    key=${1%%=*} val=${1#*=}
    case $key in
      DEVPATH) devpath=$val ;;
      DEVNAME) devname=$val; [[ $val == /* ]] || devname=/dev/$val ;;
      DEVLINKS) devlinks=$val ;;
      INTERFACE) iface=$val ;;
      SUBSYSTEM) subsystem=$val ;;
      SYSTEMD_WANTS) sdwants=$val ;;
      ACTION) action=$val ;;
      USEC_INITIALIZED) usec=$val ;;
    esac
  }

  # Listen first, then look at what is already there: nothing is missed, and
  # seeing a device twice does no harm.
  exec {mon}< <(exec stdbuf -oL udevadm monitor --udev --property 2>/dev/null)
  sleep 0.5
  # (one line per device, with what matters here: read line by line in bash,
  # the whole database takes long enough on a small machine for the boot to
  # be over, and for units to be started that were stopped meanwhile)
  local us=$'\x1f' scanning=1
  while IFS=$us read -r devpath devname devlinks iface subsystem sdwants usec; do
    [[ -n $devname && $devname != /* ]] && devname=/dev/$devname
    action=add
    finish_event
  done < <(udevadm info --export-db 2>/dev/null | awk -v us="$us" '
    /^P: / { p = substr($0, 4); next }
    /^E: DEVNAME=/ { n = substr($0, 11); next }
    /^E: DEVLINKS=/ { l = substr($0, 12); next }
    /^E: INTERFACE=/ { i = substr($0, 13); next }
    /^E: SUBSYSTEM=/ { s = substr($0, 13); next }
    /^E: SYSTEMD_WANTS=/ { w = substr($0, 17); next }
    /^E: USEC_INITIALIZED=/ { t = substr($0, 20); next }
    /^$/ { if (p != "") print p us n us l us i us s us w us t; p = n = l = i = s = w = t = "" }
    END { if (p != "") print p us n us l us i us s us w us t }')
  scanning=0
  msg "the devices that were there are looked at; now watching"

  while true; do
    if IFS= read -r -t 1 -u "$mon" line; then
      case $line in
        "") finish_event ;;
        *=*) property "$line" ;;
      esac
    elif (( $? <= 128 )); then
      msg "udevadm monitor went away"
      exit 1
    fi
    if (( ${#pending[@]} )) && [[ ! -e $RT_STATE/.booting ]]; then
      msg "boot finished, starting ${pending[*]}"
      start_units "${pending[@]}"
      pending=()
    fi
  done
}

# --------------------------------------------------------------------------

# A target is reached: the line systemd would put in the journal.
cmd_target_up() {
  load "$1"
  jlog "Reached target ${U_DESCRIPTION:-$U_UNIT}."
}

cmd_timer() {
  load "$1"
  mkdir -p /var/lib/units/timers
  exec unit-timer --name "$U_UNIT" --stamp "/var/lib/units/timers/$U_UNIT" \
    ${U_TIMER[@]+"${U_TIMER[@]}"} -- "$RT_SELF" job "$U_TIMER_SERVICE_DATA"
}

cmd_log() {
  local d=$RT_LOGDIR/$1 tty
  # (a user without a home - `createHome = false`, an sftp-only account - has
  # the logs of their services where their manager keeps its state: a logger
  # that cannot start keeps the manager from ever being up)
  mkdir -p "$d" 2>/dev/null || { d=$RT_STATE/.log/$1; mkdir -p "$d"; }
  # a user's services: copied to the console as the system's are (see the
  # top), where the user may write to it - root's, in a test VM
  if [[ -r /etc/units/console-log ]] && read -r tty < /etc/units/console-log && [[ -w $tty ]]; then
    # shellcheck disable=SC2086
    exec s6-log -d3 -b -- $RT_LOGSCRIPT "$d" "p$1: " 1 > "$tty"
  fi
  # shellcheck disable=SC2086
  exec s6-log -d3 -b -- $RT_LOGSCRIPT "$d"
}


# --------------------------------------------------------------------------
# Sockets that are not Accept=yes: their service is started with them, and
# takes them from the fd holder.  This is what starts it again when it has
# been stopped (or has stopped) and something comes for it, as systemd's
# socket unit does: until then the sockets stay open, and what comes waits.

cmd_socket_activate() {
  load "$1"
  local svc=${U_SERVICE_UNIT:?} dir=$RT_SCANDIR/${U_SERVICE_ATOM:?} n=0 entry wait=() scope_arg=()
  [[ $scope == user ]] && scope_arg=(--user)
  for entry in ${U_LISTEN[@]+"${U_LISTEN[@]}"}; do
    wait+=("$(type -P s6-fdholder-retrieve)" "$RT_FDHOLDER" "unit:$U_UNIT:$n" "$(type -P fdmove)" "$(( 3 + n ))" 0)
    n=$(( n + 1 ))
  done
  (( n )) || exit 0
  while :; do
    # the sockets are not in the holder while the socket unit is not up (a
    # condition skipped it: pipewire.socket is ConditionUser=!root): wait for
    # them quietly: this has no logger of its own, what it says goes to the
    # console (a retrieve failing every second used to, over the login screen)
    if ! s6-fdholder-list "$RT_FDHOLDER" 2>/dev/null | grep -qxF "unit:$U_UNIT:0"; then
      sleep 5
      continue
    fi
    # while the service runs, what comes is its own
    s6-svwait -D "$dir" 2>/dev/null || { sleep 1; continue; }
    "${wait[@]}" "$(type -P redirfd)" -r 0 /dev/null unit-socket-wait -n "$n" || { sleep 1; continue; }
    # (it may have been started meanwhile)
    if [[ $(s6-svstat -o up "$dir" 2>/dev/null) != true ]]; then
      msg "something came for $svc: starting it"
      PATH=$PATH:$RT_DEFAULT_PATH systemctl ${scope_arg[@]+"${scope_arg[@]}"} start --no-block "$svc"
      s6-svwait -u -t 90000 "$dir" 2>/dev/null
      # (one that fails to start does not get started in a loop)
      sleep 1
    fi
  done
}

# --------------------------------------------------------------------------
# Accept=yes sockets: the listening sockets are in the fd holder (socket-up
# put them there); this is the service that takes connections off them, and
# the program that runs for each connection.

cmd_accept_loop() {
  load "$1"
  local n=0 entry
  fdchain=()
  for entry in ${U_LISTEN[@]+"${U_LISTEN[@]}"}; do
    fdchain+=("$(type -P s6-fdholder-retrieve)" "$RT_FDHOLDER" "unit:$U_UNIT:$n" "$(type -P fdmove)" "$(( 3 + n ))" 0)
    n=$(( n + 1 ))
  done
  (( n )) || { msg "no sockets"; exit 1; }
  exec "${fdchain[@]}" "$(type -P redirfd)" -r 0 /dev/null \
    unit-accept -n "$n" -m "${U_ACCEPT_MAX:-64}" -- "$RT_SELF" accept-conn "$U_ACCEPT_DATA"
}

# One connection (on descriptor 3), one instance of the template service.
# UNIT_ACCEPT_INSTANCE is the instance name; the template was compiled with a
# placeholder in its place, which is filled in here.
cmd_accept_conn() {
  local template=$1 data inst=${UNIT_ACCEPT_INSTANCE:?}
  mkdir -p "$RT_STATE/.accept"
  data=$RT_STATE/.accept/$$.data
  sed "s/ACCEPTINSTANCEPLACEHOLDER/$inst/g" "$template" > "$data"
  load "$data"
  rm -f "$data"
  # (what the placeholder stood for is in the names the unit has now)
  set_state activating
  if ! conditions U_CONDITIONS; then
    msg "skipped: condition not met ($__u_failed_condition)"
    rm -rf "$sd"
    exit 0
  fi
  cgroup_enter
  local rc=0 privileged=0
  if ! prepare_env || ! prepare_dirs || ! prepare_creds; then
    msg "cannot set up the environment"
    set_state failed resources
    cgroup_leave
    exit 1
  fi
  fdchain=()
  run_list start_pre "$(( ${U_PERMISSIONS_START_ONLY:-0} ? 1 : 0 ))" || rc=$?
  if (( rc == 0 )); then
    expand "u_start_$(( ${U_N_START:-1} - 1 ))"
    (( ${#__u_argv[@]} )) || { msg "empty ExecStart="; rc=1; }
  fi
  if (( rc == 0 )); then
    [[ $__u_flags == *+* ]] && privileged=1
    set_state active
    (
      child_setup "$privileged"
      export PATH=$u_path
      if [[ ${U_STDIN:-null} == socket ]]; then
        # standard input is the connection; there is nothing to "listen" to
        exec 3<&-
      else
        export LISTEN_FDS=1 LISTEN_PID=$BASHPID
      fi
      exec ${pfx[@]+"${pfx[@]}"} "${__u_argv[@]}"
    )
    rc=$?
  fi
  local result=success
  (( rc == 0 )) || result=exit-code
  export SERVICE_RESULT=$result EXIT_CODE=exited EXIT_STATUS=$rc
  run_list_all stop_post "$(( ${U_PERMISSIONS_START_ONLY:-0} ? 1 : 0 ))"
  cgroup_kill 2
  cgroup_leave
  remove_runtime_dirs
  remove_creds
  rm -rf "$sd"
  exit "$rc"
}

# .path units: the unit they are for is started when something happens to a
# path.  (Looked at once a second; for what these are used for - a spool
# directory that fills, a file that is put somewhere - that is plenty.)
cmd_path() {
  load "$1"
  local entry kind path dir mode target=$U_PATH_UNIT
  local -A seen=()
  if (( ${U_PATH_MAKE_DIR:-0} )); then
    for entry in ${U_PATHS[@]+"${U_PATHS[@]}"}; do
      path=${entry#*"$RT_SEP"}
      dir=$path
      [[ ${entry%%"$RT_SEP"*} == DirectoryNotEmpty ]] || dir=${path%/*}
      mkdir -p -m "${U_PATH_DIR_MODE:-0755}" "$dir" 2>/dev/null
    done
  fi
  local firing last_start=0 now
  while true; do
    firing=0
    for entry in ${U_PATHS[@]+"${U_PATHS[@]}"}; do
      kind=${entry%%"$RT_SEP"*} path=${entry#*"$RT_SEP"}
      case $kind in
        PathExists) [[ -e $path ]] && firing=1 ;;
        PathExistsGlob)
          set +f
          for f in $path; do [[ -e $f ]] && { firing=1; break; }; done
          set -f ;;
        DirectoryNotEmpty)
          [[ -d $path && -n $(ls -A "$path" 2>/dev/null) ]] && firing=1 ;;
        PathChanged|PathModified)
          # inode, size and time of the last change tell whether it was touched
          mode=$(stat -c '%i:%s:%Y.%y' "$path" 2>/dev/null) || mode=gone
          if [[ -n ${seen[$path]+set} && ${seen[$path]} != "$mode" ]]; then firing=1; fi
          seen[$path]=$mode ;;
      esac
    done
    if (( firing )); then
      now=$EPOCHSECONDS
      # not again for a moment, whatever the unit does (systemd rate-limits too)
      if (( now - last_start >= 2 )); then
        last_start=$now
        PATH=$PATH:$RT_DEFAULT_PATH systemctl start --no-block "$target" > /dev/null 2>&1 || true
      fi
    fi
    sleep 1
  done
}

verb=${1-}
shift || true
case $verb in
  run) cmd_run "$@" ;;
  finish) cmd_finish "$@" ;;
  up) cmd_up "$@" ;;
  down) cmd_down "$@" ;;
  job) cmd_job "$@" ;;
  stop-hook) cmd_stop_hook "$@" ;;
  reload) cmd_reload "$@" ;;
  mount-up) cmd_mount_up "$@" ;;
  mount-down) cmd_mount_down "$@" ;;
  swap-up) cmd_swap_up "$@" ;;
  swap-down) cmd_swap_down "$@" ;;
  socket-up) cmd_socket_up "$@" ;;
  socket-down) cmd_socket_down "$@" ;;
  socket-activate) cmd_socket_activate "$@" ;;
  device) cmd_device "$@" ;;
  device-watch) cmd_device_watch "$@" ;;
  timer) cmd_timer "$@" ;;
  target-up) cmd_target_up "$@" ;;
  path) cmd_path "$@" ;;
  accept-loop) cmd_accept_loop "$@" ;;
  accept-conn) cmd_accept_conn "$@" ;;
  log) cmd_log "$@" ;;
  *)
    echo "usage: unit-runtime VERB DATA…  (see the comment at the top of $0)" >&2
    exit 100 ;;
esac
