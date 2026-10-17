#!@shell@
# systemd-notify - tell the supervisor about readiness from a shell script.

PATH=@path@:$PATH
RUNTIME=@runtime@

msgs=()
while (( $# )); do
  case $1 in
    --ready) msgs+=("READY=1") ;;
    --reloading) msgs+=("RELOADING=1") ;;
    --stopping) msgs+=("STOPPING=1") ;;
    --status=*) msgs+=("STATUS=${1#*=}") ;;
    --pid) msgs+=("MAINPID=$PPID") ;;
    --pid=*) msgs+=("MAINPID=${1#*=}") ;;
    --booted) exit 1 ;;   # "was the system booted with systemd?"
    --uid=*|--no-block|--exec|--fd=*|--fdname=*) ;;
    -h|--help) echo "systemd-notify [--ready] [--status=TEXT] [--pid[=PID]] [VARIABLE=VALUE…]"; exit 0 ;;
    --) shift; msgs+=("$@"); break ;;
    -*) ;;
    *) msgs+=("$1") ;;
  esac
  shift
done
(( ${#msgs[@]} )) || exit 0
exec unit-sdnotify "${msgs[@]}"
