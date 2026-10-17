#!@shell@
# unit-link - systemd.link(5) files for a udev that does not read them.
#
#   unit-link name IFACE     (from IMPORT{program}): prints the name the
#                            interface is to get, as UNIT_LINK_NAME=…
#   unit-link apply IFACE    (from RUN): applies the rest of the settings
#
# systemd-udevd reads /etc/systemd/network/*.link itself; eudev does not.
# NixOS gives interfaces their MTU and MAC address that way
# (networking.interfaces.<name>.mtu and .macAddress, in scripted networking
# too), and Wake-on-LAN, and names by MAC address.  As systemd-udevd does,
# the first file (in the order of the file names) whose [Match] fits the
# device is the one that counts.
#
# What a [Match] says that cannot be checked here makes the file not match,
# and what a [Link] asks for that is not done here is logged.

PATH=@path@
# (the lists of globs are split on spaces, and are not to be file names)
set -f -u

mode=${1-} iface=${2-}
[[ -n $mode && -n $iface ]] || { echo "usage: unit-link name|apply IFACE" >&2; exit 100; }
sys=/sys/class/net/$iface
[[ -e $sys ]] || exit 0

log() { logger -t unit-link -- "$iface: $*" 2>/dev/null || echo "unit-link: $iface: $*" >&2; }

# The .link files, /etc over /run for the same name, in the order of names.
link_files() {
  local d f
  declare -A seen=()
  # (run in a subshell of its own: the glob below is the one wanted)
  set +f
  for d in /etc/systemd/network /run/systemd/network; do
    for f in "$d"/*.link; do
      [[ -e $f ]] || continue
      [[ -n ${seen[${f##*/}]-} ]] && continue
      seen[${f##*/}]=$f
    done
  done
  for f in "${seen[@]}"; do
    # (a link to /dev/null, or an empty file, masks the name)
    [[ -s $f ]] && printf '%s\t%s\n' "${f##*/}" "$f"
  done | LC_ALL=C sort | cut -f2
}

# Reads section $2 of file $1 into the associative array S: each key's value,
# assignments to a list adding to it and an empty one emptying it.
declare -A S
read_section() {
  local file=$1 want=$2 line key val section=
  S=()
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case $line in
      '' | '#'* | ';'*) continue ;;
      '['*']') section=${line:1:${#line}-2}; continue ;;
    esac
    [[ $section == "$want" && $line == *=* ]] || continue
    key=${line%%=*} val=${line#*=}
    key=${key%"${key##*[![:space:]]}"}
    val=${val#"${val%%[![:space:]]*}"}
    if [[ -z $val ]]; then
      S[$key]=
    elif [[ -n ${S[$key]-} ]]; then
      S[$key]+=" $val"
    else
      S[$key]=$val
    fi
  done < "$file"
}

yes_no() {
  case ${1,,} in
    1 | yes | true | on) echo on ;;
    0 | no | false | off) echo off ;;
    *) return 1 ;;
  esac
}

# Does any of the words of $2 (shell globs; the list inverted if it starts
# with "!") match one of the values that follow?
glob_list() {
  local list=$1 invert=0 w v
  shift
  if [[ $list == '!'* ]]; then invert=1; list=${list#!}; fi
  for w in $list; do
    for v in "$@"; do
      # shellcheck disable=SC2053
      if [[ -n $v && $v == $w ]]; then return $invert; fi
    done
  done
  return $(( ! invert ))
}

devtype() {
  local t=
  t=$(sed -n 's/^DEVTYPE=//p' "$sys/uevent" 2>/dev/null)
  if [[ -z $t ]]; then
    case $(< "$sys/type") in
      1) t=ether ;; 772) t=loopback ;; 768) t=ipip ;; 769) t=tunnel6 ;; 776) t=sit ;;
      778) t=gre ;; 823) t=ip6gre ;; 65534) t=none ;; 280) t=can ;; 32) t=infiniband ;;
      *) t=$(< "$sys/type") ;;
    esac
  fi
  printf '%s' "$t"
}

driver() {
  if [[ -e $sys/device/driver ]]; then
    basename "$(readlink -f "$sys/device/driver")"
  else
    ethtool -i "$iface" 2>/dev/null | sed -n 's/^driver: //p'
  fi
}

kind() {
  ip -d -j link show dev "$iface" 2>/dev/null | grep -o '"info_kind":"[^"]*"' | head -1 | cut -d'"' -f4
}

# Does file $1 match the device?  ($names: what OriginalName= is matched with)
matches() {
  local file=$1 key v
  read_section "$file" Match
  for key in "${!S[@]}"; do
    v=${S[$key]}
    [[ -n $v ]] || continue
    case $key in
      OriginalName) glob_list "$v" "${names[@]}" || return 1 ;;
      # (the name the device has: nixpkgs' networking test matches on it)
      Name) glob_list "$v" "$iface" || return 1 ;;
      MACAddress) glob_list "${v,,}" "$(< "$sys/address")" || return 1 ;;
      PermanentMACAddress)
        glob_list "${v,,}" "$(ethtool -P "$iface" 2>/dev/null | sed -n 's/^Permanent address: //p')" || return 1 ;;
      Type) glob_list "$v" "$(devtype)" || return 1 ;;
      Driver) glob_list "$v" "$(driver)" || return 1 ;;
      Kind) glob_list "$v" "$(kind)" || return 1 ;;
      Path) glob_list "$v" "${ID_PATH-}" || return 1 ;;
      Property)
        local p
        for p in $v; do
          [[ $p == *=* ]] || return 1
          local pk=${p%%=*} pv=${p#*=}
          # shellcheck disable=SC2053
          [[ ${!pk-} == $pv ]] 2>/dev/null || return 1
        done ;;
      Host) glob_list "$v" "$(< /proc/sys/kernel/hostname)" || return 1 ;;
      KernelCommandLine)
        local w ok=0
        for w in $(< /proc/cmdline); do
          [[ $w == "$v" || ${w%%=*} == "$v" ]] && ok=1
        done
        (( ok )) || return 1 ;;
      *)
        log "$file: [Match] $key= is not supported here, so the file does not match"
        return 1 ;;
    esac
  done
  return 0
}

first_match() {
  local f
  while IFS= read -r f; do
    if matches "$f"; then
      printf '%s' "$f"
      return 0
    fi
  done < <(link_files)
  return 1
}

bytes() {
  local v=${1^^} n m=1
  case $v in
    *K) m=1024; v=${v%K} ;;
    *M) m=$((1024 * 1024)); v=${v%M} ;;
    *G) m=$((1024 * 1024 * 1024)); v=${v%G} ;;
  esac
  [[ $v =~ ^[0-9]+$ ]] || return 1
  n=$(( v * m ))
  printf '%s' "$n"
}

case $mode in
  name)
    names=("$iface")
    file=$(first_match) || exit 0
    read_section "$file" Link
    printf 'UNIT_LINK_FILE=%s\n' "$file"
    # (NamePolicy= is what eudev's own rules do; Name= is the fixed one)
    [[ -n ${S[Name]-} ]] && printf 'UNIT_LINK_NAME=%s\n' "${S[Name]}"
    exit 0 ;;
  apply) ;;
  *) echo "unit-link: unknown mode $mode" >&2; exit 100 ;;
esac

# OriginalName= is the name the kernel gave; after a rename by udev this
# event has it as INTERFACE_OLD.  The name it has now counts too: the
# initrd may have renamed it already.
names=("$iface")
[[ -n ${INTERFACE_OLD-} && ${INTERFACE_OLD} != "$iface" ]] && names+=("$INTERFACE_OLD")
file=$(first_match) || exit 0
read_section "$file" Link

feature() {
  local key=$1 feat=$2 b
  [[ -n ${S[$key]-} ]] || return 0
  b=$(yes_no "${S[$key]}") || { log "$file: $key=${S[$key]} is not a boolean"; return 0; }
  ethtool -K "$iface" "$feat" "$b" 2>/dev/null || log "cannot set $feat $b"
}

for key in "${!S[@]}"; do
  v=${S[$key]}
  [[ -n $v ]] || continue
  case $key in
    MACAddress)
      ip link set dev "$iface" address "$v" 2>/dev/null || log "cannot set the MAC address $v" ;;
    MTUBytes)
      if n=$(bytes "$v"); then
        ip link set dev "$iface" mtu "$n" 2>/dev/null || log "cannot set the MTU $n"
      else
        log "$file: MTUBytes=$v is not a size"
      fi ;;
    TransmitQueueLength)
      ip link set dev "$iface" txqueuelen "$v" 2>/dev/null || log "cannot set txqueuelen $v" ;;
    Alias)
      ip link set dev "$iface" alias "$v" 2>/dev/null || log "cannot set the alias" ;;
    AlternativeName)
      for a in $v; do ip link property add dev "$iface" altname "$a" 2>/dev/null; done ;;
    WakeOnLan)
      wol=
      for w in $v; do
        case $w in
          phy) wol+=p ;; unicast) wol+=u ;; multicast) wol+=m ;; broadcast) wol+=b ;;
          arp) wol+=a ;; magic) wol+=g ;; secureon) wol+=s ;; off | no | false | 0) wol=d ;;
        esac
      done
      [[ -n $wol ]] && { ethtool -s "$iface" wol "$wol" 2>/dev/null || log "cannot set Wake-on-LAN $wol"; } ;;
    AutoNegotiation)
      if b=$(yes_no "$v"); then ethtool -s "$iface" autoneg "$b" 2>/dev/null || log "cannot set autoneg $b"; fi ;;
    BitsPerSecond)
      if n=$(bytes "$v"); then
        ethtool -s "$iface" speed $(( n / 1000000 )) 2>/dev/null || log "cannot set the speed"
      fi ;;
    Duplex)
      ethtool -s "$iface" duplex "$v" 2>/dev/null || log "cannot set duplex $v" ;;
    ReceiveChecksumOffload) feature "$key" rx ;;
    TransmitChecksumOffload) feature "$key" tx ;;
    TCPSegmentationOffload) feature "$key" tso ;;
    GenericSegmentationOffload) feature "$key" gso ;;
    GenericReceiveOffload) feature "$key" gro ;;
    LargeReceiveOffload) feature "$key" lro ;;
    # naming is done before (Name=) or by eudev's own rules (the policies);
    # the rest is not about the device
    Name | NamePolicy | AlternativeNamesPolicy | MACAddressPolicy | Description) ;;
    *) log "$file: [Link] $key= is not applied here" ;;
  esac
done
exit 0
