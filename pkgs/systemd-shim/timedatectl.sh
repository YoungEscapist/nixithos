#!@shell@
# timedatectl - show and set the time, without systemd-timedated.
#
# The time zone is part of the configuration (time.timeZone); it can still be
# set here when that is left to the machine (time.timeZone = null), by
# pointing /etc/localtime at the zone.

PATH=@path@:$PATH
RUNTIME=@runtime@

verb=status args=() property=() value=0
while (( $# )); do
  case $1 in
    --no-pager|--no-ask-password|--adjust-system-clock|--monitor|-a|--all) ;;
    -p|--property) shift; property+=("${1-}") ;;
    --property=*) property+=("${1#*=}") ;;
    --value) value=1 ;;
    -H|-M|--host|--machine) shift ;;
    -h|--help) echo "timedatectl [status|show|set-time T|set-timezone ZONE|list-timezones|set-ntp BOOL|timesync-status]"; exit 0 ;;
    -*) ;;
    *) args+=("$1") ;;
  esac
  shift
done
(( ${#args[@]} )) && verb=${args[0]}

zone() {
  local target
  if target=$(readlink -f /etc/localtime 2>/dev/null) && [[ $target == */zoneinfo/* ]]; then
    printf '%s' "${target#*/zoneinfo/}"
  elif [[ -r /etc/timezone ]]; then
    cat /etc/timezone
  else
    printf 'UTC'
  fi
}

synchronized() {
  if [[ -e /run/systemd/timesync/synchronized ]] || { command -v chronyc > /dev/null && chronyc tracking 2>/dev/null | grep -q 'Leap status *: Normal'; }; then
    echo yes
  else
    echo no
  fi
}

ntp_active() {
  if s6-svstat /run/service/timesyncd 2>/dev/null | grep -q '^up'; then echo yes; else echo no; fi
}

show() {
  cat <<PROPS
Timezone=$(zone)
LocalRTC=no
CanNTP=yes
NTP=$(ntp_active)
NTPSynchronized=$(synchronized)
TimeUSec=$(date '+%a %Y-%m-%d %H:%M:%S %Z')
PROPS
}

case $verb in
  status)
    printf '               Local time: %s\n' "$(date '+%a %Y-%m-%d %H:%M:%S %Z')"
    printf '           Universal time: %s\n' "$(date -u '+%a %Y-%m-%d %H:%M:%S UTC')"
    printf '                 RTC time: %s\n' "$(date -u '+%a %Y-%m-%d %H:%M:%S')"
    printf '                Time zone: %s (%s, %s)\n' "$(zone)" "$(date +%Z)" "$(date +%z)"
    printf 'System clock synchronized: %s\n' "$(synchronized)"
    printf '              NTP service: %s\n' "$([[ $(ntp_active) == yes ]] && echo active || echo inactive)"
    printf '          RTC in local TZ: no\n' ;;
  show)
    if (( ${#property[@]} )); then
      show | while IFS== read -r k v; do
        for p in "${property[@]}"; do
          if [[ $k == "$p" ]]; then
            if (( value )); then echo "$v"; else echo "$k=$v"; fi
          fi
        done
      done
    else
      show
    fi ;;
  set-timezone)
    z=${args[1]-}
    [[ -n $z ]] || { echo "timedatectl: time zone expected" >&2; exit 1; }
    f=
    for d in /etc/zoneinfo /run/current-system/sw/share/zoneinfo /usr/share/zoneinfo; do
      [[ -e $d/$z ]] && { f=$d/$z; break; }
    done
    [[ -n $f ]] || { echo "Failed to set time zone: Invalid time zone '$z'" >&2; exit 1; }
    # (time.timeZone: /etc/localtime is made by the configuration, which
    # keeps its own copy of the link in /etc/static)
    if [[ -L /etc/static/localtime ]]; then
      echo "Failed to set time zone: /etc/localtime is managed by the configuration (time.timeZone)" >&2
      exit 1
    fi
    if ! ln -sfn "$f" /etc/localtime 2>/dev/null; then
      echo "Failed to set time zone: /etc/localtime is managed by the configuration (time.timeZone)" >&2
      exit 1
    fi ;;
  list-timezones)
    for d in /etc/zoneinfo /run/current-system/sw/share/zoneinfo /usr/share/zoneinfo; do
      if [[ -d $d ]]; then
        (cd "$d" && find . -type f -path './*/*' ! -path './posix/*' ! -path './right/*' | sed 's|^\./||' | sort)
        break
      fi
    done ;;
  set-time)
    t=${args[1]-}
    [[ -n $t ]] || { echo "timedatectl: time expected" >&2; exit 1; }
    date -s "$t" > /dev/null || exit 1 ;;
  set-ntp|set-local-rtc)
    # the NTP client is a service of the configuration (services.timesyncd, chrony…)
    exit 0 ;;
  timesync-status)
    if [[ -e /run/systemd/timesync/synchronized ]]; then
      echo "       Packet count: -"
      echo "  Synchronized since: $(date -r /run/systemd/timesync/synchronized '+%a %Y-%m-%d %H:%M:%S %Z')"
    else
      echo "Not synchronized"
    fi ;;
  *)
    echo "timedatectl: unknown command $verb" >&2
    exit 1 ;;
esac
