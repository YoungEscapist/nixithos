#!@shell@
# hostnamectl - show or set the host name, without systemd-hostnamed.

PATH=@path@:$PATH
RUNTIME=@runtime@

verb=status transient=0 static=0 args=()
while (( $# )); do
  case $1 in
    --transient) transient=1 ;;
    --static) static=1 ;;
    --pretty|--no-ask-password|--json=*|-j) ;;
    -H|-M|--host|--machine) shift ;;
    -h|--help) echo "hostnamectl [status | hostname [NAME] | set-hostname NAME]"; exit 0 ;;
    -*) ;;
    *) args+=("$1") ;;
  esac
  shift
done
(( ${#args[@]} )) && verb=${args[0]}

current=$(< /proc/sys/kernel/hostname)
case $verb in
  status)
    echo " Static hostname: $(cat /etc/hostname 2>/dev/null || echo "(unset)")"
    [[ -r /etc/hostname && $(< /etc/hostname) == "$current" ]] || echo "Transient hostname: $current"
    [[ -r /etc/machine-id ]] && echo "      Machine ID: $(< /etc/machine-id)"
    echo "         Boot ID: $(tr -d - < /proc/sys/kernel/random/boot_id)"
    echo "          Kernel: Linux $(< /proc/sys/kernel/osrelease)"
    echo "    Architecture: $(uname -m)" ;;
  hostname|set-hostname)
    name=${args[1]-}
    if [[ -z $name ]]; then
      [[ $verb == hostname ]] && { echo "$current"; exit 0; }
      echo "hostnamectl: host name expected" >&2
      exit 1
    fi
    if (( static )) && (( ! transient )); then
      echo "hostnamectl: the static host name is part of the system configuration (networking.hostName)" >&2
      exit 1
    fi
    # /etc/hostname belongs to the configuration; only the running kernel is
    # told.  Where the host name agent runs (modules/services/hostname.nix),
    # it is what does it, as systemd-hostnamed would: for users it allows,
    # and for the host even from a service with a UTS namespace of its own.
    agent=/run/hostname-agent/socket
    if [[ -S $agent ]]; then
      reply=$(s6-ipcclient -- "$agent" "$BASH" -c \
        'printf "transient %s\n" "$1" >&7 && read -r -t 10 r <&6 && printf "%s" "$r"' _ "$name" 2>/dev/null)
      [[ $reply == ok ]] && exit 0
      echo "hostnamectl: could not set the host name: ${reply:-no answer from the host name agent}" >&2
      exit 1
    fi
    if ! { echo "$name" > /proc/sys/kernel/hostname; } 2>/dev/null; then
      echo "hostnamectl: could not set the host name (not root?)" >&2
      exit 1
    fi ;;
  set-icon-name|set-chassis|set-deployment|set-location|icon-name|chassis|deployment|location)
    exit 0 ;;
  *)
    echo "hostnamectl: unknown command $verb" >&2
    exit 1 ;;
esac
