#!@shell@
# loginctl - for a system without a login manager (services.elogind): users
# can still be made to linger, which is what keeps their service manager
# running without a session.  Sessions and seats are elogind's.

PATH=@path@:$PATH
RUNTIME=@runtime@

LINGER=/var/lib/systemd/linger

verb=${1-list-sessions}
shift || true
args=()
while (( $# )); do
  case $1 in
    --no-pager|--no-legend|--no-ask-password|-a|--all|-l|--full|--value) ;;
    -p|--property|-H|-M|--host|--machine|-o|--output|-n|--lines) shift ;;
    -*) ;;
    *) args+=("$1") ;;
  esac
  shift
done

user_name() {
  local u=$1 n
  if [[ $u =~ ^[0-9]+$ ]]; then
    n=$(id -nu "$u" 2>/dev/null) || return 1
    printf '%s' "$n"
  else
    id -u "$u" > /dev/null 2>&1 || return 1
    printf '%s' "$u"
  fi
}

case $verb in
  enable-linger|disable-linger)
    rc=0
    targets=("${args[@]}")
    (( ${#targets[@]} )) || targets=("$(id -un)")
    for u in "${targets[@]}"; do
      if ! n=$(user_name "$u"); then
        echo "Failed to $verb: user $u is not known" >&2
        rc=1
        continue
      fi
      if [[ $verb == enable-linger ]]; then
        mkdir -p "$LINGER" && : > "$LINGER/$n" || rc=1
      else
        rm -f "$LINGER/$n"
      fi
    done
    exit $rc ;;
  show-user|user-status)
    u=${args[0]-$(id -un)}
    n=$(user_name "$u") || { echo "Failed to look up user $u" >&2; exit 1; }
    l=no
    [[ -e $LINGER/$n ]] && l=yes
    printf 'UID=%s\nName=%s\nLinger=%s\nState=%s\n' "$(id -u "$n")" "$n" "$l" "$([[ -d /run/user/$(id -u "$n") ]] && echo active || echo closing)" ;;
  list-users)
    echo "UID USER LINGER STATE" ;;
  list-sessions|list-seats)
    echo "No sessions." ;;
  terminate-user|terminate-session|kill-user|kill-session|lock-sessions|unlock-sessions|lock-session|unlock-session|activate)
    exit 0 ;;
  --version|version)
    echo "loginctl (no login manager; lingering only)" ;;
  -h|--help|help)
    echo "loginctl enable-linger|disable-linger [USER…] | show-user [USER]"
    echo "(sessions and seats need services.elogind.enable)" ;;
  *)
    echo "loginctl: '$verb' needs a login manager (services.elogind.enable)" >&2
    exit 1 ;;
esac
