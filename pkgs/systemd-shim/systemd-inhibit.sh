#!@shell@
# systemd-inhibit - run a command while holding a shutdown/sleep inhibitor.
# Inhibitors belong to the login manager; if elogind is there, its tool is
# used.  Otherwise there is nobody to honour them, but `--list` shows them
# as systemd's would (borgbackup's test looks for its own): this program
# stays, as the parent of the command, for as long as it runs, and the list
# is read from the arguments of the ones running.  Nothing is written
# anywhere, so it works from inside any sandbox (ProtectSystem=strict).

PATH=@path@:$PATH
RUNTIME=@runtime@

if command -v elogind-inhibit > /dev/null 2>&1; then
  exec elogind-inhibit "$@"
fi

# parse_options ARGS…: sets what who why mode list, and rest to the command
parse_options() {
  what="idle:sleep:shutdown" who= why="Unknown reason" mode=block list=0 legend=1 rest=()
  while (( $# )); do
    case $1 in
      --what=*) what=${1#*=} ;;
      --who=*) who=${1#*=} ;;
      --why=*) why=${1#*=} ;;
      --mode=*) mode=${1#*=} ;;
      --what) shift; what=${1-} ;;
      --who) shift; who=${1-} ;;
      --why) shift; why=${1-} ;;
      --mode) shift; mode=${1-} ;;
      --list) list=1 ;;
      --no-legend) legend=0 ;;
      --no-pager|--no-ask-password) ;;
      --) shift; break ;;
      -*) ;;
      *) break ;;
    esac
    shift
  done
  rest=("$@")
  [[ -n $who ]] || who="${rest[*]}"
}

parse_options "$@"
# (as systemd's: with no command to run, the locks are listed - restic's test
# looks for its own that way)
(( ${#rest[@]} )) || list=1
show_legend=$legend

if (( list )); then
  n=0 rows=()
  for d in /proc/[0-9]*; do
    pid=${d#/proc/}
    [[ $pid == "$$" ]] && continue
    args=()
    # (a process may be gone by now)
    while IFS= read -r -d '' a; do args+=("$a"); done 2>/dev/null < "$d/cmdline"
    # (the shell running this script: its argument is the script's path)
    (( ${#args[@]} > 1 )) && [[ ${args[1]} == */systemd-inhibit ]] || continue
    parse_options "${args[@]:2}"
    # (another listing, or one without a command: nothing held)
    (( list )) && continue
    (( ${#rest[@]} )) || continue
    uid=$(stat -c %u "$d" 2>/dev/null) || continue
    user=$(id -nu "$uid" 2>/dev/null || echo "$uid")
    rows+=("$who"$'\t'"$uid"$'\t'"$user"$'\t'"$pid"$'\t'"${rest[0]##*/}"$'\t'"$what"$'\t'"$why"$'\t'"$mode")
    n=$(( n + 1 ))
  done
  {
    (( show_legend )) && printf 'WHO\tUID\tUSER\tPID\tCOMM\tWHAT\tWHY\tMODE\n'
    (( n )) && printf '%s\n' "${rows[@]}"
  } | column -t -s $'\t'
  (( show_legend )) && printf '\n%d inhibitors listed.\n' "$n"
  exit 0
fi

# in the background, but with this standard input, not /dev/null
"${rest[@]}" <&0 &
child=$!
trap 'kill -TERM "$child" 2>/dev/null' TERM INT HUP
while :; do
  wait "$child"
  rc=$?
  # (a signal that came in ends the wait, not the command)
  kill -0 "$child" 2>/dev/null || break
done
exit "$rc"
