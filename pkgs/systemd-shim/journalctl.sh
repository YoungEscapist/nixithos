#!@shell@
# journalctl - read the logs s6-log keeps under /var/log/s6, with the options
# people type out of habit.  There is no journal: every service has a plain
# text log directory, and `tail -F /var/log/s6/NAME/current` works just as well.

PATH=@path@:$PATH
RUNTIME=@runtime@
set -u

LOGDIR=/var/log/s6
follow=0 lines= units=() kernel=0 grep_pat= ident= reverse=0 all_boots=1 output=short

while (( $# )); do
  case $1 in
    -u|--unit) shift; units+=("${1-}") ;;
    --unit=*) units+=("${1#*=}") ;;
    -u*) units+=("${1#-u}") ;;
    -f|--follow) follow=1 ;;
    -n|--lines) shift; lines=${1-10} ;;
    --lines=*) lines=${1#*=} ;;
    -n*) lines=${1#-n} ;;
    -e|--pager-end) lines=${lines:-1000} ;;
    -k|--dmesg) kernel=1 ;;
    -g|--grep) shift; grep_pat=${1-} ;;
    --grep=*) grep_pat=${1#*=} ;;
    -t|--identifier) shift; ident=${1-} ;;
    --identifier=*) ident=${1#*=} ;;
    -r|--reverse) reverse=1 ;;
    -b|--boot|-x|--catalog|-a|--all|-q|--quiet|--no-pager|--no-hostname|--no-full|-l|--full|--system|-m|--merge|--utc) ;;
    -o|--output) shift; output=${1-short} ;;
    --output=*) output=${1#*=} ;;
    -o*) output=${1#-o} ;;
    -b*|--boot=*|-p*|--priority=*|--since=*|--until=*|-S*|-U*|--no-tail|--flush|--sync|--rotate) ;;
    -p|--priority|--since|--until|-S|-U|--vacuum-size|--vacuum-time|-D|--directory|--file) shift ;;
    --vacuum-*|--disk-usage) du -sh "$LOGDIR" 2>/dev/null; exit 0 ;;
    -h|--help)
      echo "journalctl [-u UNIT]… [-k] [-f] [-n LINES] [-g PATTERN] [-r]"
      echo "Reads $LOGDIR/NAME/ (written by s6-log); other journalctl options are accepted and ignored."
      exit 0 ;;
    --version) echo "journalctl (s6-log reader) 0.1"; exit 0 ;;
    _*=*|[A-Z]*=*)
      # field matches: only the unit ones mean something here
      case $1 in _SYSTEMD_UNIT=*|UNIT=*) units+=("${1#*=}") ;; esac ;;
    -*) ;;
    *) ;;
  esac
  shift
done

# unit name -> log directory name (the s6 service name)
atom_of() {
  local name=$1 live db unit kind type rank boot atom rest
  case $name in *.service|*.socket|*.target|*.mount|*.timer|*.swap|*.path) ;; *) name=$name.service ;; esac
  live=$(readlink -f /run/s6-rc/compiled 2>/dev/null) || live=
  db=${live%/*}
  [[ -n $live ]] || db=$(readlink -f /run/current-system/s6-db 2>/dev/null)
  if [[ -r $db/index.tsv ]]; then
    while IFS=$'\t' read -r unit kind type rank boot atom rest; do
      if [[ $unit == "$name" ]]; then printf '%s' "$atom"; return; fi
    done < "$db/index.tsv"
  fi
  printf '%s' "${name%.service}"
}

# what the service manager says about units ("Started …", "Reloaded …"):
# one file per unit, written by unit-runtime
STATE=/run/units
events=()

dirs=()
(( kernel )) && dirs+=("$LOGDIR/klogd")
for u in ${units[@]+"${units[@]}"}; do
  dirs+=("$LOGDIR/$(atom_of "$u")")
  case $u in *.service|*.socket|*.target|*.mount|*.timer|*.swap|*.path) ;; *) u=$u.service ;; esac
  events+=("$STATE/$u/journal")
done
if (( ${#dirs[@]} == 0 )); then
  for d in "$LOGDIR"/*/; do [[ -d $d ]] && dirs+=("${d%/}"); done
  [[ -d /run/uncaught-logs ]] && dirs+=(/run/uncaught-logs)
  for d in "$STATE"/*/journal; do [[ -r $d ]] && events+=("$d"); done
  # (the users' managers say their part too, as they do in a journal: with the
  # same identifier, "systemd")
  for d in /run/user-managers/.state/*/units/*/journal; do [[ -r $d ]] && events+=("$d"); done
fi

# Print the lines of one log directory, oldest first, tagged with its name.
dump() {
  local d=$1 name=${1##*/} f
  [[ -d $d ]] || return 0
  [[ $name == uncaught-logs ]] && name=init
  for f in "$d"/@*.[su] "$d"/current; do
    [[ -r $f ]] && sed -e "s/^\([^ ]* [^ ]*\)  */\1 $name: /" "$f"
  done
}

dump_events() {
  local f=$1
  [[ -r $f ]] && sed -e 's/^\([^ ]* [^ ]*\)  */\1 systemd[1]: /' "$f"
  return 0
}

# -g PATTERN: as journalctl's, matched against the message (not the date and
# name in front of it: "^audit:" is the start of the message), ignoring case
# unless the pattern has capitals in it; nothing found is a failure.
filter() {
  if [[ -n $ident ]]; then
    # -t NAME: the name in front of the message (a log directory's, or
    # "systemd" for the unit events), without its [pid]
    ID=$ident awk '{ n = $3; sub(/:$/, "", n); sub(/\[[0-9]+\]$/, "", n); if (n == ENVIRON["ID"]) print }' |
      { ident= filter; }
  elif [[ -n $grep_pat ]]; then
    local icase=0
    [[ $grep_pat == *[[:upper:]]* ]] || icase=1
    PAT=$grep_pat ICASE=$icase awk '
      { m = $0; sub(/^[^ ]+ [^ ]+ [^ ]+ ?/, "", m)
        if (ENVIRON["ICASE"] == 1) { m = tolower(m); p = tolower(ENVIRON["PAT"]) } else p = ENVIRON["PAT"]
        if (m ~ p) { print; n++ } }
      END { exit n ? 0 : 1 }'
  else
    cat
  fi
}

if (( follow )); then
  files=()
  for d in "${dirs[@]}"; do [[ -e $d/current ]] && files+=("$d/current"); done
  for d in ${events[@]+"${events[@]}"}; do [[ -e $d ]] && files+=("$d"); done
  (( ${#files[@]} )) || { echo "journalctl: no logs found" >&2; exit 1; }
  exec tail -n "${lines:-10}" -F "${files[@]}"
fi

out() {
  {
    for d in "${dirs[@]}"; do dump "$d"; done
    for f in ${events[@]+"${events[@]}"}; do dump_events "$f"; done
  } | sort -s -k1,2 | filter | format
}

# -o cat: the messages alone (the date, the time and the name in front of them
# are the first three words)
format() {
  case $output in
    cat) sed -E 's/^[^ ]+ [^ ]+ [^ ]+ ?//' ;;
    *) cat ;;
  esac
}

# (a -g that finds nothing makes the exit status)
set -o pipefail
if (( reverse )); then
  if [[ -n $lines ]]; then out | tail -n "$lines" | tac; else out | tac; fi
elif [[ -n $lines ]]; then
  out | tail -n "$lines"
else
  out
fi
