#!@shell@
# unit-sandbox - the file system (and network) view of one command of a
# sandboxed unit: PrivateTmp=, PrivateDevices=, ProtectSystem=, ProtectHome=,
# ReadOnlyPaths= and the rest of that family of systemd.exec(5).
#
#   unit-sandbox [OPTIONS] -- COMMAND [ARGUMENTS…]
#
# The process is already in namespaces of its own: unit-runtime starts it
# through `unshare --mount` (plus --net, --uts, --ipc where asked), so
# nothing done here is seen by anyone else.  When the view is set up, the
# command is executed with the environment it came with.
#
# A path with a leading `-` may be missing; any other that is missing is
# reported and skipped (systemd refuses to start the service instead).
#
# Options:
#   --stage DIR           a writable directory of the unit to build things in
#   --root DIR            RootDirectory=: everything below happens inside DIR
#                         (the program does not chroot: unit-chroot does)
#   --api-vfs             MountAPIVFS=: /proc, /sys, /dev and an empty /run in it
#   --private-tmp DIR     /tmp and /var/tmp are DIR/tmp and DIR/var-tmp
#   --private-devices     a /dev of its own with the harmless nodes only
#   --protect-system M    yes | full | strict
#   --protect-home M      yes | read-only | tmpfs
#   --read-only P         P and everything below it read-only
#   --read-write P        P writable again (inside something read-only)
#   --inaccessible P      P is empty and cannot be entered
#   --bind S:D[:OPTS]     S mounted on D (OPTS: ro, norbind)
#   --tmpfs P[:OPTS]      a fresh tmpfs on P
#   --kernel-tunables     /proc/sys, /sys… read-only
#   --cgroups             /sys/fs/cgroup read-only
#   --loopback            bring `lo` up (after --net)
#   --private-mounts      (nothing: only the mount namespace itself)
#   --private-network     (nothing: unit-runtime made the namespace)

ORIG_PATH=$PATH
PATH=@path@
set -u

# The unit's UMask= is for what the command makes; the directories made here
# (mount points in a RootDirectory=, say) are as systemd makes them, or a
# UMask=0077 leaves a root that its user cannot walk through.
ORIG_UMASK=$(umask)
umask 0022

stage= private_tmp= devices=0 system= home= tunables=0 cgroups=0 loopback=0 R= apivfs=0 run_rw=0
ro=() rw=() inacc=() binds=() tmpfs=()

die() { echo "unit-sandbox: $*" >&2; exit 226; }
warn() { echo "unit-sandbox: warning: $*" >&2; }

while (( $# )); do
  case $1 in
    --stage) stage=$2; shift ;;
    --private-tmp) private_tmp=$2; shift ;;
    --private-devices) devices=1 ;;
    --root) R=${2%/}; shift ;;
    --api-vfs) apivfs=1 ;;
    --protect-system) system=$2; shift ;;
    --protect-home) home=$2; shift ;;
    --read-only) ro+=("$2"); shift ;;
    --read-write) rw+=("$2"); shift ;;
    --inaccessible) inacc+=("$2"); shift ;;
    --bind) binds+=("$2"); shift ;;
    --tmpfs) tmpfs+=("$2"); shift ;;
    --kernel-tunables) tunables=1 ;;
    --cgroups) cgroups=1 ;;
    --loopback) loopback=1 ;;
    --strict-run-writable) run_rw=1 ;;
    --private-mounts|--private-network) ;;
    --) shift; break ;;
    *) die "unknown option $1" ;;
  esac
  shift
done
(( $# )) || die "no command"

(( loopback )) && { ip link set lo up 2>/dev/null || warn "cannot bring up lo"; }

# Nothing that follows may reach the host's mounts.
mount --make-rprivate / || die "cannot make mounts private"

# Where a path of the unit is: inside its root directory, if it has one.
inside() { printf '%s%s' "$R" "$1"; }

# The "-" (may be missing) off a path, the root directory in front of it, and
# whether it is there.
resolve() {
  local p=$1
  case $p in
    -*) p=${p#-}; p=$(inside "${p#[+!]}"); [[ -e $p ]] || return 1 ;;
    *) p=$(inside "${p#[+!]}"); [[ -e $p ]] || { warn "$p does not exist"; return 1; } ;;
  esac
  printf '%s' "$p"
}

# (unit-mnt makes the path a mount point of its own first, so that what is done
# to it is a property of that path and nothing else, and does a whole tree of
# mounts in one go)
make_ro() {
  local p
  p=$(resolve "$1") || return 0
  unit-mnt ro "$p" 2>/dev/null || warn "cannot make $p read-only"
}

make_rw() {
  local p
  p=$(resolve "$1") || return 0
  unit-mnt rw "$p" 2>/dev/null || warn "cannot make $p writable"
}

hide() {
  local p
  p=$(resolve "$1") || return 0
  if [[ -d $p ]]; then
    mount -t tmpfs -o mode=0000,size=4k,nr_inodes=1,ro tmpfs "$p" 2>/dev/null || warn "cannot hide $p"
  else
    # a file: an empty, unreadable one on top of it
    local f=${stage:-/run}/.inaccessible.$$
    : > "$f"
    chmod 000 "$f"
    mount --bind -- "$f" "$p" 2>/dev/null || warn "cannot hide $p"
    mount -o remount,bind,ro -- "$p" 2>/dev/null || true
    # (the mount keeps the file; the name is not needed)
    rm -f -- "$f"
  fi
}

# --------------------------------------------------------------------------
# the root directory

if [[ -n $R ]]; then
  [[ -d $R ]] || die "RootDirectory= $R is not there"
  # a mount point of its own, so that it can be made read-only as a whole
  mount --rbind -- "$R" "$R" || die "cannot use $R as a root"
  if (( apivfs )); then
    for p in /proc /sys; do
      mkdir -p -- "$R$p" && mount --rbind -- "$p" "$R$p" 2>/dev/null || warn "no $p in the root"
    done
    if (( ! devices )); then
      mkdir -p -- "$R/dev" && mount --rbind -- /dev "$R/dev" 2>/dev/null || warn "no /dev in the root"
    fi
    mkdir -p -- "$R/run" && mount -t tmpfs -o mode=0755 tmpfs "$R/run" 2>/dev/null || warn "no /run in the root"
  fi
fi

# --------------------------------------------------------------------------
# a /dev of its own

if (( devices )); then
  [[ -d $stage ]] || die "--private-devices needs --stage"
  d=$stage/dev.$$
  mkdir -p "$d" || die "cannot make $d"
  mount -t tmpfs -o mode=0755,nosuid,strictatime tmpfs "$d" || die "cannot mount a tmpfs for /dev"
  # (log: syslog(3) goes to /dev/log, from a service with a private /dev as
  # from any other; systemd gives it a /dev/log as well)
  for n in null zero full random urandom tty log; do
    [[ -e /dev/$n ]] || continue
    : > "$d/$n"
    mount --bind "/dev/$n" "$d/$n" 2>/dev/null || { rm -f "$d/$n"; warn "no /dev/$n"; }
  done
  ln -s /proc/self/fd "$d/fd"
  ln -s /proc/self/fd/0 "$d/stdin"
  ln -s /proc/self/fd/1 "$d/stdout"
  ln -s /proc/self/fd/2 "$d/stderr"
  [[ -e /proc/kcore ]] && ln -s /proc/kcore "$d/core"
  mkdir -p "$d/pts" "$d/shm" "$d/mqueue"
  if mount -t devpts -o newinstance,ptmxmode=0666,mode=0620,gid=5 devpts "$d/pts" 2>/dev/null; then
    ln -s pts/ptmx "$d/ptmx"
  else
    warn "no private /dev/pts"
  fi
  mount -t tmpfs -o mode=1777,nosuid,nodev tmpfs "$d/shm" 2>/dev/null || warn "no /dev/shm"
  mount -t mqueue mqueue "$d/mqueue" 2>/dev/null || rmdir "$d/mqueue" 2>/dev/null
  mkdir -p -- "$(inside /dev)"
  mount --move "$d" "$(inside /dev)" || die "cannot put the private /dev in place"
  rmdir "$d" 2>/dev/null
fi

# --------------------------------------------------------------------------
# things made of nothing, and bind mounts

for entry in ${tmpfs[@]+"${tmpfs[@]}"}; do
  p=${entry%%:*}
  opts=
  [[ $entry == *:* ]] && opts=${entry#*:}
  p=$(inside "${p#[+!]}")
  # (a tmpfs may be mounted where there is nothing yet)
  [[ -d $p ]] || mkdir -p -- "$p" 2>/dev/null
  [[ -d $p ]] || { warn "cannot make $p"; continue; }
  mount -t tmpfs -o "mode=0755${opts:+,$opts}" tmpfs "$p" || warn "cannot mount a tmpfs on $p"
done

case $home in
  tmpfs)
    for p in /home /root /run/user; do
      [[ -d $(inside $p) ]] && mount -t tmpfs -o mode=0755 tmpfs "$(inside $p)" 2>/dev/null
    done ;;
esac

# bind SRC (a path, or /proc/self/fd/N) on DST (as the unit sees it)
bind_one() {
  local src=$1 dst=$2 opts=$3 flags=--rbind
  dst=$(inside "$dst")
  if [[ ! -e $dst ]]; then
    if [[ -d $src ]]; then
      mkdir -p "$dst" 2>/dev/null
    else
      # (a file: its directory may not be there either, in a root of its own)
      mkdir -p "${dst%/*}" 2>/dev/null
      : > "$dst" 2>/dev/null
    fi
  fi
  [[ ,$opts, == *,norbind,* ]] && flags=--bind
  # (mount would make /proc/self/fd/N the path it names, which is the new,
  # empty directory by now)
  [[ $src == /proc/self/fd/* ]] && flags+=" --no-canonicalize"
  # shellcheck disable=SC2086
  mount $flags -- "$src" "$dst" || { warn "cannot bind $src on $dst"; return 0; }
  [[ ,$opts, == *,ro,* ]] && mount -o remount,bind,ro -- "$dst" 2>/dev/null
  return 0
}

# A bind into /tmp or /var/tmp (BindReadOnlyPaths=/tmp/bird) goes onto the
# private one, made further down, as systemd puts it; by then the path of
# its source is the private one too, so the source is held open meanwhile.
#
# What is around goes before what is inside it, as systemd orders its mounts
# by their paths: BindPaths=/etc/wpa_supplicant stays writable under a
# BindReadOnlyPaths=/etc/ that comes after it in the unit.
sorted_binds=()
while IFS= read -r line; do
  [[ -n $line ]] && sorted_binds+=("${line#*$'\t'}")
done < <(
  for i in ${binds[@]+"${!binds[@]}"}; do
    IFS=: read -r s d _ <<< "${binds[$i]}"
    s=${s#-} && s=${s#[+!]}
    d=${d:-$s} && d=${d%/}
    n=${d//[!\/]/}
    printf '%03d %05d\t%s\n' "${#n}" "$i" "${binds[$i]}"
  done | sort
)
late_binds=() rw_binds=()
for entry in ${sorted_binds[@]+"${sorted_binds[@]}"}; do
  IFS=: read -r src dst opts <<< "$entry"
  optional=0
  case $src in -*) optional=1; src=${src#-} ;; esac
  src=${src#[+!]}
  [[ -n $dst ]] || dst=$src
  if [[ ! -e $src ]]; then
    (( optional )) || warn "bind source $src does not exist"
    continue
  fi
  if [[ -n $private_tmp ]]; then
    case $dst in
      /tmp | /tmp/* | /var/tmp | /var/tmp/*)
        if exec {held}< "$src"; then
          late_binds+=("$held:$dst:$opts")
        else
          warn "cannot open $src"
        fi
        continue ;;
    esac
  fi
  bind_one "$src" "$dst" "$opts"
  [[ ,$opts, == *,ro,* ]] || rw_binds+=("$dst")
done

for p in ${inacc[@]+"${inacc[@]}"}; do hide "$p"; done

# --------------------------------------------------------------------------
# read-only

case $system in
  yes) for p in /usr /boot /efi; do make_ro "-$p"; done ;;
  full) for p in /usr /boot /efi /etc; do make_ro "-$p"; done ;;
  strict)
    # every mount there is but the API file systems
    unit-mnt strict ${R:+"$R"} 2>/dev/null || warn "cannot make the file system read-only"
    # What systemd leaves writable for ProtectHome= to deal with (below), and
    # /run where it leaves that too (with ProtectProc=, see unitc).
    (( run_rw )) && [[ -d $(inside /run) ]] && unit-mnt rw "$(inside /run)" 2>/dev/null
    for p in /home /root /run/user; do
      [[ -d $(inside $p) ]] && unit-mnt rw "$(inside $p)" 2>/dev/null
    done ;;
esac

case $home in
  yes) for p in /home /root /run/user; do [[ -e $(inside $p) ]] && hide "$p"; done ;;
  read-only) for p in /home /root /run/user; do make_ro "-$p"; done ;;
  tmpfs) for p in /home /root /run/user; do [[ -d $(inside $p) ]] && unit-mnt ro "$(inside $p)" 2>/dev/null; done ;;
esac

for p in ${ro[@]+"${ro[@]}"}; do make_ro "$p"; done

if (( tunables )); then
  for p in /proc/sys /proc/sysrq-trigger /proc/latency_stats /proc/acpi /proc/timer_stats \
           /proc/fs /proc/irq /proc/bus /sys; do
    make_ro "-$p"
  done
fi
(( cgroups )) && make_ro "-/sys/fs/cgroup"

# --------------------------------------------------------------------------
# writable again

if [[ -n $private_tmp ]]; then
  for pair in tmp:/tmp var-tmp:/var/tmp; do
    src=$private_tmp/${pair%%:*} dst=$(inside "${pair#*:}")
    # (a root directory has nothing yet)
    [[ -n $R && ! -d $dst ]] && mkdir -p -- "$dst" 2>/dev/null
    [[ -d $src && -d $dst ]] || continue
    mount --bind -- "$src" "$dst" || { warn "cannot make a private $dst"; continue; }
    mount -o remount,bind,rw,nosuid,nodev -- "$dst" 2>/dev/null || true
  done
fi

for entry in ${late_binds[@]+"${late_binds[@]}"}; do
  IFS=: read -r held dst opts <<< "$entry"
  bind_one "/proc/self/fd/$held" "$dst" "$opts"
  # (made after ProtectSystem=, so not read-only by it: writable, as a bind
  # is under systemd, unless asked for otherwise)
  [[ ,$opts, == *,ro,* ]] || mount -o remount,bind,rw -- "$(inside "$dst")" 2>/dev/null
  exec {held}<&-
done

for p in ${rw[@]+"${rw[@]}"}; do make_rw "$p"; done

# BindPaths= stays writable under ProtectSystem=strict and the like, as with
# systemd (wpa_supplicant saves its configuration through one)
for p in ${rw_binds[@]+"${rw_binds[@]}"}; do
  mount -o remount,bind,rw -- "$(inside "$p")" 2>/dev/null
done

# The working directory was entered before any of the above: it is the
# directory as it was, under the mounts that were made over it since (a
# StateDirectory= made writable under ProtectSystem=strict is a mount of its
# own).  Entering it again goes through the mounts in place now.
cd -- "$(pwd -P)" 2>/dev/null || true

# RootDirectory=: the directory becomes the root of the namespace, as systemd
# makes it (MS_MOVE onto /), so that what enters the namespace (nsenter -m,
# aesmd's test) finds the service's files where the service does.  This
# process keeps the old root as its own, so the commands that follow still
# run from the store; unit-chroot is handed the new root by a descriptor.
if [[ -n $R ]]; then
  exec {rootfd}< "$R"
  if mount --move -- "$R" / 2>/dev/null; then
    args=() done_=0
    for a in "$@"; do
      if (( ! done_ )) && [[ $a == "$R" ]]; then a=/proc/self/fd/$rootfd; done_=1; fi
      args+=("$a")
    done
    set -- "${args[@]}"
  else
    warn "cannot make $R the root of the namespace"
    exec {rootfd}<&-
  fi
fi

PATH=$ORIG_PATH
umask "$ORIG_UMASK"
exec "$@"
