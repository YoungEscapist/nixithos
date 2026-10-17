#!@shell@
# systemd-escape - turn strings and paths into unit name components and back.

PATH=@path@:$PATH
RUNTIME=@runtime@

path=0 unescape=0 suffix= template=
args=()
while (( $# )); do
  case $1 in
    -p|--path) path=1 ;;
    -u|--unescape) unescape=1 ;;
    -m|--mangle) ;;
    --suffix=*) suffix=${1#*=} ;;
    --suffix) shift; suffix=$1 ;;
    --template=*) template=${1#*=} ;;
    --template) shift; template=$1 ;;
    --) shift; args+=("$@"); break ;;
    *) args+=("$1") ;;
  esac
  shift
done

escape() {
  local s=$1 out= c i
  if (( path )); then
    while [[ $s == *//* ]]; do s=${s//\/\//\/}; done
    s=${s#/}; s=${s%/}
    [[ -z $s ]] && { printf '%s' -; return; }
  fi
  for (( i = 0; i < ${#s}; i++ )); do
    c=${s:i:1}
    case $c in
      /) out+=- ;;
      [a-zA-Z0-9:_]) out+=$c ;;
      .) if (( i == 0 )); then out+='\x2e'; else out+=.; fi ;;
      *) out+=$(printf '%s' "$c" | od -An -tx1 | tr -d '\n' | sed 's/ /\\x/g') ;;
    esac
  done
  printf '%s' "$out"
}

unesc() {
  local s=$1
  [[ -n $suffix ]] && s=${s%."$suffix"}
  s=${s//-//}
  s=$(printf '%b' "$s")
  (( path )) && s=/$s
  printf '%s' "$s"
}

first=1
for a in "${args[@]}"; do
  (( first )) || printf ' '
  first=0
  if (( unescape )); then
    unesc "$a"
  else
    e=$(escape "$a")
    if [[ -n $template ]]; then
      printf '%s' "${template%@.*}@$e.${template##*.}"
    else
      printf '%s' "$e${suffix:+.$suffix}"
    fi
  fi
done
echo
