#!@shell@
# systemd-analyze - the subcommands that make sense without systemd:
# `calendar` (when does a timer expression elapse next), `verify` (accepted;
# units are checked when the system is built) and `security` (what a unit's
# sandbox settings amount to: systemd's own analyzer, reading the unit file -
# see client-tools.nix).

PATH=@path@:$PATH
RUNTIME=@runtime@
ANALYZE=@analyze@

all=("$@")
args=()
while (( $# )); do
  case $1 in
    --iterations=*|--no-pager|--system|--user|--man=*|--recursive-errors=*) ;;
    -*) ;;
    *) args+=("$1") ;;
  esac
  shift
done

case ${args[0]-} in
  security)
    if (( ${#args[@]} < 2 )); then
      echo "systemd-analyze: security needs unit names on this system" >&2
      exit 1
    fi
    if [[ -z $ANALYZE ]]; then
      echo "systemd-analyze: security is not available on this system" >&2
      exit 1
    fi
    # the unit files are the system's (/etc/systemd/system); there is no
    # service manager to ask, so --offline, whatever was given
    # (a unit named without its suffix is a service, as systemctl has it; the
    # offline analyzer wants the file's name)
    opts=() seen=0 value=0
    for a in "${all[@]}"; do
      if (( value )); then opts+=("$a"); value=0; continue; fi
      case $a in
        --offline|--offline=*|--no-pager|--system) ;;
        --threshold|--root|--image|--profile|--security-policy|--host|-H|--machine|-M) opts+=("$a"); value=1 ;;
        -*) opts+=("$a") ;;
        *)
          if (( seen )) && [[ $a != */* && $a != *.* ]]; then a=$a.service; fi
          [[ $a == security ]] && seen=1
          opts+=("$a") ;;
      esac
    done
    exec "$ANALYZE" --no-pager --offline=true "${opts[@]}" ;;
  calendar)
    rc=0
    for expr in "${args[@]:1}"; do
      if next=$(unit-timer --next "$expr" 2>&1); then
        echo "  Original form: $expr"
        echo "    Next elapse: $next"
      else
        echo "Failed to parse calendar specification '$expr'" >&2
        rc=1
      fi
    done
    exit $rc ;;
  verify) exit 0 ;;
  ""|time|blame|critical-chain)
    echo "systemd-analyze: boot timing is not recorded; see /run/uncaught-logs for the boot log" >&2
    exit 1 ;;
  *)
    echo "systemd-analyze: '${args[0]}' is not available on this system" >&2
    exit 1 ;;
esac
