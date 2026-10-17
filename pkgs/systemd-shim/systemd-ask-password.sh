#!@shell@
# systemd-ask-password - ask for a password on the terminal.

PATH=@path@:$PATH
RUNTIME=@runtime@

prompt="Password:" echo_mode=0
while (( $# )); do
  case $1 in
    --echo|--echo=yes) echo_mode=1 ;;
    --timeout=*|--icon=*|--id=*|--keyname=*|--credential=*|--emoji=*|--echo=*|--no-tty|--accept-cached|--multiple|-n|--no-output) ;;
    --timeout|--icon|--id|--keyname|--credential) shift ;;
    -*) ;;
    *) prompt=$* ; break ;;
  esac
  shift
done

tty=/dev/tty
[[ -r $tty && -w $tty ]] || tty=/dev/console
if (( echo_mode )); then
  read -r -p "$prompt " answer < "$tty" 2> "$tty"
else
  read -r -s -p "$prompt " answer < "$tty" 2> "$tty"
  echo > "$tty"
fi
printf '%s\n' "$answer"
