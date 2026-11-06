#!@shell@
# nixith-snapshots - read-only btrfs snapshots of the system before it is
# switched to a new configuration; see ../../modules/system/snapshots.nix.
#
#   nixith-snapshots create [ACTION [TOPLEVEL]]   take one now (the hook of
#                                                 switch-to-configuration)
#   nixith-snapshots list                         the snapshots there are
#   nixith-snapshots delete ID...                 remove some
#   nixith-snapshots prune                        keep only the newest N
#
# A snapshot is a directory ID under the snapshot directory, with a file
# `info` and, for each subvolume that is snapshotted, a read-only snapshot
# of it: /.snapshots/7/root (the @ subvolume, /), /.snapshots/7/home (@home).
# Plain btrfs; nothing but this script knows about them.  To go back to one:
# `btrfs subvolume snapshot /.snapshots/7/root /new-root` from the top level
# of the file system, and boot into that (rootflags=subvol=...).

PATH=@path@:$PATH
set -u

default_dir=@dir@
dir=${NIXITH_SNAPSHOT_DIR:-$default_dir}
keep=${NIXITH_SNAPSHOT_KEEP:-@keep@}
paths=(@paths@)

die() {
  echo "nixith-snapshots: $*" >&2
  exit 1
}

# the name a path has as a snapshot: / is root, /home home, /var/lib var-lib
snap_name() {
  local n=${1#/}
  n=${n//\//-}
  echo "${n:-root}"
}

# is $1 the root of a btrfs subvolume?  (that is what inode 256 is)
is_subvolume() {
  [[ $(stat -f -c %T -- "$1" 2>/dev/null) == btrfs && $(stat -c %i -- "$1" 2>/dev/null) == 256 ]]
}

ids() {
  local d
  for d in "$dir"/*/; do
    [[ ! -L ${d%/} ]] || continue
    d=${d%/}
    d=${d##*/}
    [[ $d =~ ^[0-9]+$ ]] && echo "$d"
  done | sort -n
}

info_get() {
  sed -n "s/^$2=//p" "$dir/$1/info" 2>/dev/null | head -n1
}

create() {
  local action=${1:-manual} toplevel=${2:-}
  local p todo=()
  for p in "${paths[@]}"; do
    if is_subvolume "$p"; then todo+=("$p"); fi
  done
  if [[ ${#todo[@]} == 0 ]]; then
    echo "nixith-snapshots: nothing to snapshot (none of ${paths[*]} is a btrfs subvolume)" >&2
    return 0
  fi
  [[ $(stat -f -c %T -- "$dir" 2>/dev/null) == btrfs ]] ||
    die "$dir is not on a btrfs file system"

  local last id
  last=$(ids | tail -n1)
  id=$((${last:-0} + 1))
  mkdir -p -- "$dir/$id" || die "cannot create $dir/$id"
  local made=() failed=0
  for p in "${todo[@]}"; do
    if btrfs subvolume snapshot -r -- "$p" "$dir/$id/$(snap_name "$p")" > /dev/null; then
      made+=("$(snap_name "$p")")
    else
      echo "nixith-snapshots: could not snapshot $p" >&2
      failed=1
    fi
  done
  if (( failed || ${#made[@]} == 0 )); then
    for p in "${made[@]}"; do btrfs subvolume delete -- "$dir/$id/$p" >/dev/null || true; done
    rmdir -- "$dir/$id" 2>/dev/null
    die "snapshot set is incomplete"
  fi
  {
    echo "date=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "action=$action"
    echo "from=$(readlink -f /run/current-system 2>/dev/null)"
    echo "to=$toplevel"
    echo "subvolumes=${made[*]}"
  } > "$dir/$id/info"
  echo "snapshot $id taken (${made[*]}) before $action" >&2
  prune
}

list() {
  local id n=0
  for id in $(ids); do
    if ((n == 0)); then printf '%-5s %-19s %-9s %-14s %s\n' ID DATE BEFORE SUBVOLUMES SYSTEM; fi
    n=$((n + 1))
    local from
    from=$(info_get "$id" from)
    printf '%-5s %-19s %-9s %-14s %s\n' "$id" "$(info_get "$id" date)" "$(info_get "$id" action)" \
      "$(info_get "$id" subvolumes | tr ' ' ',')" "${from##*/}"
  done
  if ((n == 0)); then echo "no snapshots in $dir"; fi
}

delete_one() {
  local id=$1 s
  [[ $id =~ ^[0-9]+$ && -d $dir/$id && ! -L $dir/$id ]] || die "no snapshot $id"
  for s in "$dir/$id"/*/; do
    [[ -d $s && ! -L ${s%/} ]] || continue
    btrfs subvolume delete -- "${s%/}" > /dev/null || die "could not delete ${s%/}"
  done
  rm -f -- "$dir/$id/info"
  rmdir -- "$dir/$id" || die "could not remove $dir/$id"
  echo "snapshot $id deleted" >&2
}

prune() {
  local all n id
  mapfile -t all < <(ids)
  n=$((${#all[@]} - keep))
  for ((i = 0; i < n; i++)); do
    delete_one "${all[$i]}" || true
  done
}

[[ $(id -u) == 0 ]] || die "this wants root"
cmd=${1:-list}
[[ $# -gt 0 ]] && shift
[[ $keep =~ ^[1-9][0-9]*$ ]] || die "keep must be a positive integer"
case $cmd in
  create|delete|rm|prune)
    [[ -d $dir && ! -L $dir ]] || die "$dir must be an existing snapshot directory"
    umask 077
    exec 9>"$dir/.lock" || die "cannot open snapshot lock"
    flock -x 9 || die "cannot lock snapshots"
    ;;
esac
case $cmd in
  create) create "$@" ;;
  list | ls) list ;;
  delete | rm)
    [[ $# -gt 0 ]] || die "delete which snapshot? (an ID from the list)"
    for id in "$@"; do delete_one "$id"; done
    ;;
  prune) prune ;;
  *)
    echo "Usage: nixith snapshots [list | delete ID... | create | prune]" >&2
    exit 1
    ;;
esac
