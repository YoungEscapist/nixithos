#!@shell@
# systemd-run - run a command now, detached from the caller.
#
# There are no transient units here.  What callers want from systemd-run is
# almost always "start this in the background and return" (udev rules, hooks),
# so that is what it does; with --wait, --pty, --pipe or --scope the command
# runs in the foreground instead.

PATH=@path@:$PATH
RUNTIME=@runtime@
set -u

foreground=0 delay= unit= uid= gid= workdir= envs=() envfiles=() user=0 machine= stdout= stderr=

# -p KEY=VALUE: what a command started this way can be given without a
# service manager to keep a unit for it; the rest is accepted and ignored.
property() {
  local kv=$1 k v
  k=${kv%%=*} v=${kv#*=}
  case $k in
    StandardOutput) stdout=$v ;;
    StandardError) stderr=$v ;;
    WorkingDirectory) workdir=$v ;;
    Environment) envs+=("$v") ;;
    EnvironmentFile) envfiles+=("$v") ;;
    User) uid=$v ;;
    Group) gid=$v ;;
  esac
}

while (( $# )); do
  case $1 in
    --wait|--pty|-t|--pipe|-P|--scope) foreground=1 ;;
    --user) user=1 ;;
    --no-block|--collect|-G|--quiet|-q|--system|--remain-after-exit|-r|--send-sighup|--no-ask-password|--same-dir|-d|--shell|-S) ;;
    --unit) shift; unit=${1-} ;;
    --unit=*) unit=${1#*=} ;;
    -u) shift; unit=${1-} ;;
    --uid) shift; uid=${1-} ;;
    --uid=*) uid=${1#*=} ;;
    --gid) shift; gid=${1-} ;;
    --gid=*) gid=${1#*=} ;;
    --working-directory) shift; workdir=${1-} ;;
    --working-directory=*) workdir=${1#*=} ;;
    --setenv=*) envs+=("${1#*=}") ;;
    -E|--setenv) shift; envs+=("${1-}") ;;
    --on-active=*) delay=${1#*=} ;;
    --on-active) shift; delay=${1-} ;;
    -p|--property) shift; property "${1-}" ;;
    --property=*) property "${1#*=}" ;;
    -p*) property "${1#-p}" ;;
    -M|--machine) shift; machine=${1-} ;;
    --machine=*) machine=${1#*=} ;;
    --description|--slice|--service-type|--nice|--on-boot|--on-startup|--on-unit-active|--on-unit-inactive|--on-calendar|--timer-property|--path-property|--socket-property|-H|--host) shift ;;
    --description=*|--slice=*|--service-type=*|--nice=*|--on-*=*|--timer-property=*|--expand-environment=*|--background=*) ;;
    --) shift; break ;;
    -*) echo "systemd-run: ignoring option $1" >&2 ;;
    *) break ;;
  esac
  shift
done

# --user --machine=USER@: in that user's manager, which is to say as that
# user, with what their services have (runtime directory, session bus)
if (( user )) && [[ -n $machine && ${machine%%@*} != "" && ${machine%%@*} != .host ]]; then
  uid=${machine%%@*}
fi
user_env=()
if (( user )) && [[ -n $uid ]]; then
  pw=$(getent passwd "$uid") || { echo "systemd-run: no such user $uid" >&2; exit 1; }
  IFS=: read -r pw_name _ pw_uid _ _ pw_home pw_shell <<< "$pw"
  user_env=(HOME="$pw_home" USER="$pw_name" LOGNAME="$pw_name" SHELL="$pw_shell"
    XDG_RUNTIME_DIR="/run/user/$pw_uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$pw_uid/bus")
fi
(( $# )) || { echo "systemd-run: command to execute is missing" >&2; exit 1; }

cmd=("$@")
if [[ -n $uid || -n $gid ]]; then
  cmd=(setpriv ${uid:+--reuid "$uid"} ${gid:+--regid "$gid"} --init-groups -- "${cmd[@]}")
fi

redirect() {
  # redirect FD SPEC
  case $2 in
    file:*) eval "exec $1<>\"\${2#file:}\"" ;;
    append:*) eval "exec $1>>\"\${2#append:}\"" ;;
    truncate:*) eval "exec $1>\"\${2#truncate:}\"" ;;
    null) eval "exec $1>/dev/null" ;;
  esac
}

launch() {
  [[ -n $workdir ]] && { [[ $workdir == "~" ]] && workdir=${pw_home:-$HOME}; cd "$workdir" || exit 200; }
  for e in ${user_env[@]+"${user_env[@]}"}; do export "$e"; done
  # EnvironmentFile=: KEY=VALUE lines, # and ; comments, quotes taken off;
  # with "-" in front it may be missing
  local f line k v
  for f in ${envfiles[@]+"${envfiles[@]}"}; do
    if [[ $f == -* ]]; then f=${f#-}; [[ -r $f ]] || continue; fi
    [[ -r $f ]] || { echo "systemd-run: cannot read $f" >&2; exit 1; }
    while IFS= read -r line || [[ -n $line ]]; do
      line=${line#"${line%%[![:space:]]*}"}
      [[ -z $line || $line == \#* || $line == \;* || $line != *=* ]] && continue
      k=${line%%=*} v=${line#*=}
      k=${k%"${k##*[![:space:]]}"} k=${k#export }
      v=${v#"${v%%[![:space:]]*}"}
      if [[ $v == \"*\" || $v == \'*\' ]]; then v=${v:1:${#v}-2}; fi
      export "$k=$v"
    done < "$f"
  done
  for e in ${envs[@]+"${envs[@]}"}; do
    if [[ $e == *=* ]]; then export "$e"; else export "$e=${!e-}"; fi
  done
  [[ -n $stdout ]] && redirect 1 "$stdout"
  # (StandardError= follows StandardOutput= unless it is given)
  if [[ -n $stderr ]]; then redirect 2 "$stderr"; elif [[ -n $stdout ]]; then exec 2>&1; fi
  if [[ -n $delay ]]; then sleep "${delay%s}"; fi
  exec "${cmd[@]}"
}

if (( foreground )); then
  launch
fi

tag=${unit:-run-$$}
cmd=(setsid "${cmd[@]}")
( exec < /dev/null > >(exec logger -t "$tag") 2>&1; launch ) &
disown
echo "Running as unit: $tag" >&2
exit 0
