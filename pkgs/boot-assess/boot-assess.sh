#!@shell@
# nixith-boot-assess: a new generation is "on trial" until it has booted.
#
#   arm TOPLEVEL   (the boot loader installer, after it) the generation that
#                  was just installed to boot from is put on trial: the boot
#                  loader will try it @tries@ time(s) and, if it does not get
#                  to the end of the boot, fall back to the generation that
#                  runs now
#   good           (the end of the boot) this boot got there; if it was a
#                  trial, the generation stays the default for good.  If a
#                  trial was over and an older generation booted, the trial
#                  is written down as a rollback.
#   status         what is on trial, what was rolled back
#   note           the same, only if there is anything to say
#   ack            forget the last rollback
#
# What "the boot loader tries it" means, by loader (modules/system/boot-assessment.nix):
#   systemd-boot   boot counting: the entry's file name gets +N, the loader
#                  counts it down at each boot and puts an entry with 0 left
#                  last; the end of the boot takes the +N away
#   grub           grubenv: nixith_trial/nixith_good/nixith_tries, read by a
#                  piece of grub.cfg that counts down and picks the entry
#   limine         Limine cannot count or remember anything: its default is
#                  the old generation, the new one is started once through a
#                  UEFI boot entry for the kernel (BootNext)
set -u
export PATH=@path@

loader=@loader@
tries=@tries@
required=(@required@)
bootDir=@bootDir@
espDir=@espDir@
efiSupport=@efiSupport@
grubEditenv=@grubEditenv@
efibootmgr=@efibootmgr@

STATE=/var/lib/nixith/boot-assessment
PROFILES=/nix/var/nix/profiles
reason=

say() { echo "boot assessment: $*" >&2; }
klog() { echo "<4>nixith-boot-assess: $*" > /dev/kmsg 2> /dev/null || true; }

# ---------------------------------------------------------------- state

sget() { # FILE KEY
    [[ -r $STATE/$1 ]] || return 0
    sed -n "s/^$2=//p" "$STATE/$1" | head -n1
}

# the number of the generation of the system profile that is STORE PATH $1
gen_of() {
    local l n best=
    for l in "$PROFILES"/system-*-link; do
        [[ -e $l ]] || continue
        [[ $(readlink -f "$l") == "$1" ]] || continue
        n=${l##*/system-}
        n=${n%-link}
        [[ -z $best || $n -gt $best ]] && best=$n
    done
    echo "$best"
}

describe() { # TOPLEVEL -> "generation N" or the path
    local n
    n=$(gen_of "$1")
    if [[ -n $n ]]; then echo "generation $n"; else echo "$1"; fi
}

lock() {
    mkdir -p /run/nixith
    exec 8> /run/nixith/boot-assess.lock
    flock 8
}

# ---------------------------------------------------------------- systemd-boot

sd_dir() { echo "$bootDir/loader/entries"; }

# sd_parse FILE: s_stem, s_left, s_done (empty for an entry nobody counts)
sd_parse() {
    local b=${1##*/}
    b=${b%.conf}
    if [[ $b =~ ^(.*)\+([0-9]+)(-([0-9]+))?$ ]]; then
        s_stem=${BASH_REMATCH[1]}
        s_left=${BASH_REMATCH[2]}
        s_done=${BASH_REMATCH[4]:-0}
    else
        s_stem=$b
        s_left=
        s_done=
    fi
}

# the entry files (counted or not) that start the system TOPLEVEL
sd_entries_for() {
    local f
    for f in "$(sd_dir)"/nixos*-generation-*.conf; do
        [[ -e $f ]] || continue
        awk -v want="init=$1/init" '$1 == "options" { for (i = 2; i <= NF; i++) if ($i == want) ok = 1 } END { exit !ok }' "$f" &&
            echo "$f"
    done
}

# the link of the generation that an entry's stem stands for
sd_link_of_stem() {
    if [[ $1 =~ ^nixos-generation-([0-9]+) ]]; then
        echo "$PROFILES/system-${BASH_REMATCH[1]}-link"
    elif [[ $1 =~ ^nixos-(.+)-generation-([0-9]+) ]]; then
        echo "$PROFILES/system-profiles/${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-link"
    fi
}

# loader.conf's `default`: the installer names the entry of the generation it
# installs for, and systemd-boot takes the entry that `default` names even when
# it has no tries left (also `@saved`).  So while a generation is on trial
# there is no `default`: the loader takes the first entry that is not bad, the
# newest.  When the trial is over `default` names an entry again.
sd_set_default() { # VALUE, or nothing: no `default`
    local conf=$espDir/loader/loader.conf tmp
    [[ -f $conf ]] || return 0
    tmp=$conf.nixith.$$
    grep -v '^default ' "$conf" > "$tmp"
    [[ -z ${1-} ]] || echo "default $1" >> "$tmp"
    mv -f "$tmp" "$conf"
}

sd_set_default_for() { # TOPLEVEL: its entry, as the installer would
    local f
    for f in $(sd_entries_for "$1"); do
        sd_parse "$f"
        [[ $s_stem == *-specialisation-* ]] && continue
        sd_set_default "$s_stem.conf"
        return 0
    done
    return 0
}

sd_arm() { # TOPLEVEL GOOD
    local top=$1 good=$2 dir f has_good=0 link
    dir=$(sd_dir)
    [[ -d $dir ]] || { reason="there is no $dir"; return 1; }

    # The installer writes every entry anew: next to an entry that is being
    # counted it makes a plain one, which would be a generation that has no
    # trial and, if it failed, one that has been given up on.  It also does
    # not know the counted ones, and never removes those of old generations.
    for f in "$dir"/nixos*+*.conf; do
        [[ -e $f ]] || continue
        sd_parse "$f"
        [[ -n $s_left ]] || continue
        rm -f "$dir/$s_stem.conf"
        link=$(sd_link_of_stem "$s_stem")
        if [[ -n $link && ! -e $link ]]; then rm -f "$f"; fi
    done

    for f in $(sd_entries_for "$good"); do
        sd_parse "$f"
        [[ -z $s_left ]] && has_good=1
    done
    ((has_good)) || { reason="the boot menu has no entry for the generation that runs"; return 1; }

    # A generation that was put on trial and has not been booted since gives
    # way to this one: it is now one nobody may fall into.
    local mine
    mine=$(sd_entries_for "$top")
    for f in "$dir"/nixos*+*.conf; do
        [[ -e $f ]] || continue
        sd_parse "$f"
        [[ -n $s_left && $s_left -gt 0 ]] || continue
        grep -qxF "$f" <<< "$mine" && continue
        mv -f "$f" "$dir/$s_stem+0-$tries.conf"
    done

    local armed=0
    for f in $mine; do
        sd_parse "$f"
        [[ -z $s_left ]] || continue
        # (not a specialisation of it: it is a way to boot this generation,
        # but not the one that is tried)
        [[ $s_stem == *-specialisation-* ]] && continue
        mv -f "$f" "$dir/$s_stem+$tries.conf"
        armed=1
    done
    ((armed)) || { reason="the boot menu has no new entry for it"; return 1; }
    sd_set_default
    return 0
}

sd_clean() { # tidy what the installer left
    local f link
    for f in "$(sd_dir)"/nixos*+*.conf; do
        [[ -e $f ]] || continue
        sd_parse "$f"
        [[ -n $s_left ]] || continue
        rm -f "$(sd_dir)/$s_stem.conf"
        link=$(sd_link_of_stem "$s_stem")
        if [[ -n $link && ! -e $link ]]; then rm -f "$f"; fi
    done
    return 0
}

sd_good() { # TOPLEVEL: take the count off its entries
    local f
    for f in $(sd_entries_for "$1"); do
        sd_parse "$f"
        [[ -n $s_left ]] || continue
        mv -f "$f" "$(sd_dir)/$s_stem.conf"
    done
    sd_set_default_for "$1"
    sync -f "$bootDir" 2> /dev/null || true
    return 0
}

# is TOPLEVEL still to be tried (some tries left)?
sd_pending() {
    local f
    for f in $(sd_entries_for "$1"); do
        sd_parse "$f"
        [[ -n $s_left && $s_left -gt 0 ]] && return 0
    done
    return 1
}

sd_failed() { sd_set_default_for "$2"; sync -f "$bootDir" 2> /dev/null || true; return 0; }

# ---------------------------------------------------------------- grub

grub_cfg() { echo "$bootDir/grub/grub.cfg"; }
grub_env() { echo "$bootDir/grub/grubenv"; }
grub_id() { local h=${1#/nix/store/}; echo "nixith-${h:0:12}"; }

# Names the entries, so that grub.cfg can pick them by what they start:
# --id nixith-<start of the store hash of the system>; the menu of all
# configurations is nixith-all.
grub_idify() {
    awk '
      { l[NR] = $0 }
      END {
        for (i = 1; i <= NR; i++) {
          line = l[i]
          if (line ~ /^submenu .*All configurations.* \{$/ && line !~ /--id /) {
            sub(/ \{$/, " --id nixith-all {", line)
          } else if (line ~ /^[ \t]*menuentry .* \{$/ && line !~ /--id /) {
            for (j = i + 1; j <= NR && l[j] !~ /^[ \t]*\}/; j++) {
              if (match(l[j], /init=\/nix\/store\/[a-z0-9]+/)) {
                sub(/ \{$/, " --id nixith-" substr(l[j], RSTART + 16, 12) " {", line)
                break
              }
            }
          }
          print line
        }
      }' "$1"
}

grub_arm() { # TOPLEVEL GOOD
    local top=$1 good=$2 cfg tmp
    cfg=$(grub_cfg)
    [[ -f $cfg ]] || { reason="there is no $cfg"; return 1; }
    [[ -n $grubEditenv ]] || { reason="no grub-editenv"; return 1; }
    tmp=$cfg.nixith.$$
    grub_idify "$cfg" > "$tmp" && cat "$tmp" > "$cfg"
    rm -f "$tmp"
    grep -qF -- "--id $(grub_id "$good") " "$cfg" || { reason="grub.cfg has no entry for the generation that runs"; return 1; }
    grep -qF -- "--id $(grub_id "$top") " "$cfg" || { reason="grub.cfg has no entry for the new generation"; return 1; }
    [[ -e $(grub_env) ]] || "$grubEditenv" "$(grub_env)" create
    "$grubEditenv" "$(grub_env)" set \
        "nixith_trial=$(grub_id "$top")" \
        "nixith_good=nixith-all>$(grub_id "$good")" \
        "nixith_tries=$tries" || { reason="grubenv cannot be written"; return 1; }
    sync -f "$bootDir" 2> /dev/null || true
    return 0
}

grub_clean() {
    if [[ -n $grubEditenv && -e $(grub_env) ]]; then
        "$grubEditenv" "$(grub_env)" unset nixith_trial nixith_good nixith_tries 2> /dev/null || true
        sync -f "$bootDir" 2> /dev/null || true
    fi
    return 0
}

grub_good() { grub_clean; }

grub_pending() {
    [[ -n $grubEditenv && -e $(grub_env) ]] || return 1
    local env t
    env=$("$grubEditenv" "$(grub_env)" list 2> /dev/null) || return 1
    grep -q '^nixith_trial=.' <<< "$env" || return 1
    t=$(sed -n 's/^nixith_tries=//p' <<< "$env")
    [[ $t =~ ^[0-9]+$ && $t -gt 0 ]]
}

# the trial is over: grub.cfg still has the failed generation first, so it
# keeps being sent to the good one until the next install writes it anew
grub_failed() {
    [[ -n $grubEditenv && -e $(grub_env) ]] || return 0
    "$grubEditenv" "$(grub_env)" set nixith_tries=0 2> /dev/null || true
    sync -f "$bootDir" 2> /dev/null || true
    return 0
}

# ---------------------------------------------------------------- limine

lim_conf() { echo "$bootDir/limine/limine.conf"; }

# the number Limine gives the entry of TOPLEVEL (it counts every line that
# starts with /, directories too)
lim_index() {
    awk -v want="init=$1/init" '
      /^\/+/ { n++ }
      /^[ \t]*cmdline:/ { for (i = 2; i <= NF; i++) if ($i == want) { print n; exit } }' "$(lim_conf)"
}

lim_set_default() { # INDEX
    local conf tmp
    conf=$(lim_conf)
    tmp=$conf.nixith.$$
    sed "s/^default_entry:.*/default_entry: $1/" "$conf" > "$tmp" && mv -f "$tmp" "$conf"
}

# the lines of the entry INDEX: K kernel, C cmdline, M module, tab separated
lim_entry() {
    awk -v want="$1" '
      /^\/+/ { n++; next }
      n == want && /^[ \t]*kernel_path:/ { sub(/^[ \t]*kernel_path:[ \t]*/, ""); print "K\t" $0 }
      n == want && /^[ \t]*cmdline:/ { sub(/^[ \t]*cmdline:[ \t]*/, ""); print "C\t" $0 }
      n == want && /^[ \t]*module_path:/ { sub(/^[ \t]*module_path:[ \t]*/, ""); print "M\t" $0 }' "$(lim_conf)"
}

lim_trial_entries() {
    "$efibootmgr" 2> /dev/null | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\)\*\{0,1\} NixithOS trial.*/\1/p'
}

lim_drop_trial() {
    local b
    [[ -n $efibootmgr && -d /sys/firmware/efi/efivars ]] || return 0
    for b in $(lim_trial_entries); do
        "$efibootmgr" -b "$b" -B > /dev/null 2>&1 || true
    done
    "$efibootmgr" -N > /dev/null 2>&1 || true
}

# path of a file on the ESP, as Limine's config names it, -> its EFI path
lim_efi_path() {
    local p=${1#boot\(\):}
    p=${p%%#*}
    [[ -e $bootDir$p ]] || return 1
    printf '%s' "${p//\//\\}"
}

lim_arm() { # TOPLEVEL GOOD
    local top=$1 good=$2 conf ti gi kind val m kernel= cmdline= initrds=() src name part disk out b
    conf=$(lim_conf)
    [[ -n $efiSupport ]] || { reason="Limine without EFI cannot start something once"; return 1; }
    [[ -n $efibootmgr && -d /sys/firmware/efi/efivars ]] || { reason="the firmware's variables cannot be written (efivars)"; return 1; }
    [[ -f $conf ]] || { reason="there is no $conf"; return 1; }
    ti=$(lim_index "$top")
    gi=$(lim_index "$good")
    [[ -n $ti ]] || { reason="limine.conf has no entry for the new generation"; return 1; }
    [[ -n $gi ]] || { reason="limine.conf has no entry for the generation that runs"; return 1; }
    while IFS=$'\t' read -r kind val; do
        case $kind in
            K) kernel=$(lim_efi_path "$val") || { reason="the kernel is not on the ESP"; return 1; } ;;
            C) cmdline=$val ;;
            M)
                m=$(lim_efi_path "$val") || { reason="the initrd is not on the ESP"; return 1; }
                initrds+=("$m")
                ;;
        esac
    done < <(lim_entry "$ti")
    [[ -n $kernel && -n $cmdline ]] || { reason="the entry has no kernel or no command line"; return 1; }
    for b in "${initrds[@]}"; do cmdline+=" initrd=$b"; done

    src=$(findmnt -no SOURCE "$bootDir") && src=$(readlink -f "$src") || { reason="cannot tell where the ESP is"; return 1; }
    name=${src##*/}
    part=$(< "/sys/class/block/$name/partition") || { reason="the ESP is not a partition"; return 1; }
    disk=/dev/$(basename "$(readlink -f "/sys/class/block/$name/..")")

    lim_drop_trial
    out=$("$efibootmgr" -C -d "$disk" -p "$part" -L "NixithOS trial" -l "$kernel" -u "$cmdline" 2>&1) ||
        { reason="efibootmgr: $out"; return 1; }
    b=$(sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\)\*\{0,1\} NixithOS trial.*/\1/p' <<< "$out" | head -n1)
    [[ -n $b ]] || { reason="efibootmgr did not make the entry"; return 1; }
    "$efibootmgr" -n "$b" > /dev/null 2>&1 || { reason="BootNext cannot be set"; return 1; }
    lim_set_default "$gi"
    sync -f "$bootDir" 2> /dev/null || true
    return 0
}

lim_clean() { lim_drop_trial; return 0; }

lim_good() { # TOPLEVEL
    local i
    lim_drop_trial
    if [[ -f $(lim_conf) ]]; then
        i=$(lim_index "$1")
        [[ -n $i ]] && lim_set_default "$i"
        sync -f "$bootDir" 2> /dev/null || true
    fi
    return 0
}

# BootNext is used up by the one try
lim_pending() {
    [[ -n $efibootmgr && -d /sys/firmware/efi/efivars ]] || return 1
    "$efibootmgr" 2> /dev/null | grep -q '^BootNext:'
}

lim_failed() { lim_drop_trial; }

# ---------------------------------------------------------------- the loaders

case $loader in
    systemd-boot) p=sd ;;
    grub) p=grub ;;
    limine) p=lim ;;
    *) p= ;;
esac

backend() { # FUNCTION ARGS...
    local f=$1
    shift
    [[ -n $p ]] || return 0
    "${p}_$f" "$@"
}

# ---------------------------------------------------------------- commands

cmd_arm() {
    local top good
    top=$(readlink -f "${1:?arm TOPLEVEL}") || return 1
    [[ -n $p ]] || return 0
    # a chroot (nixos-install) has nothing that booted
    [[ -e /run/booted-system ]] || return 0
    good=$(readlink -f /run/booted-system)
    lock
    mkdir -p "$STATE"
    rm -f "$STATE/rolled-back"

    if [[ $top == "$good" ]]; then
        # (the system that runs is the one to boot: nothing to fall back to)
        rm -f "$STATE/trial"
        backend clean
        return 0
    fi
    if backend arm "$top" "$good"; then
        {
            echo "toplevel=$top"
            echo "good=$good"
            echo "tries=$tries"
            echo "loader=$loader"
            echo "time=$(date '+%F %T')"
        } > "$STATE/trial"
        say "$(describe "$top") is on trial: $tries $([[ $loader == limine ]] && echo 'try (once, through a UEFI boot entry)' || echo 'tries') before the boot loader goes back to $(describe "$good")"
    else
        rm -f "$STATE/trial"
        backend clean
        say "not armed ($reason): the boot loader will not fall back if $(describe "$top") fails to boot"
    fi
    return 0
}

good_body() {
    local booted trial u state gen msg
    booted=$(readlink -f /run/booted-system 2> /dev/null) || return 0
    [[ -n $p ]] || return 0
    lock
    mkdir -p "$STATE"
    trial=$(sget trial toplevel)

    if [[ -n $trial && $trial != "$booted" ]]; then
        if backend pending "$trial"; then
            say "$(describe "$trial") is still on trial (it has tries left); this is $(describe "$booted")"
            outcome=on-trial
            return 0
        fi
        # The trial is over and an older generation booted: the new one did
        # not get to the end of the boot (or it was never started).
        {
            echo "failed=$trial"
            echo "restored=$booted"
            echo "tries=$(sget trial tries)"
            echo "time=$(date '+%F %T')"
        } > "$STATE/rolled-back"
        # the system profile follows what runs, so that the next `boot`,
        # `switch --rollback` or bootloader install starts from it
        if [[ $(readlink -f "$PROFILES/system") == "$trial" ]]; then
            gen=$(gen_of "$booted")
            [[ -n $gen ]] && ln -sfn "system-$gen-link" "$PROFILES/system"
        fi
        backend failed "$trial" "$booted"
        rm -f "$STATE/trial"
        msg="$(describe "$trial") did not boot (not in $(sget rolled-back tries) tries); rolled back to $(describe "$booted")"
        say "$msg"
        klog "$msg"
        echo "$booted" > "$STATE/good"
        outcome=rolled-back
        return 0
    fi

    # the units this boot has to have brought up
    for u in "${required[@]}"; do
        state=
        [[ -r /run/units/$u/state ]] && state=$(< "/run/units/$u/state")
        if [[ $state != active ]]; then
            msg="$u is ${state:-not started}: $(describe "$booted") is not marked as good"
            say "$msg"
            klog "$msg"
            outcome=not-good
            return 1
        fi
    done

    backend good "$booted"
    echo "$booted" > "$STATE/good"
    if [[ -n $trial ]]; then
        rm -f "$STATE/trial"
        msg="$(describe "$booted") booted: it is the default for good"
        say "$msg"
        klog "$msg"
        outcome=good-trial
    else
        outcome=good
    fi
    return 0
}

# (what the end of this boot came to: /run/nixith/boot-assessed)
outcome=nothing
cmd_good() {
    local rc
    good_body "$@"
    rc=$?
    mkdir -p /run/nixith
    echo "$outcome" > /run/nixith/boot-assessed
    return $rc
}

cmd_status() {
    local booted trial
    if [[ -n $p ]]; then
        echo "Boot assessment: on ($loader, $tries tries)"
    else
        echo "Boot assessment: off in this system"
    fi
    booted=$(readlink -f /run/booted-system 2> /dev/null) || booted=
    [[ -n $booted ]] && echo "Booted:     $(describe "$booted")"
    trial=$(sget trial toplevel)
    if [[ -n $trial ]]; then
        if [[ $trial == "$booted" ]]; then
            echo "On trial:   $(describe "$trial") (this one; marked good at the end of the boot)"
        else
            echo "On trial:   $(describe "$trial"), the boot loader falls back to $(describe "$(sget trial good)")"
        fi
    else
        echo "On trial:   nothing"
    fi
    [[ -r /run/nixith/boot-assessed ]] && echo "This boot:  $(< /run/nixith/boot-assessed)"
    if [[ -r $STATE/rolled-back ]]; then
        echo "Rolled back: $(describe "$(sget rolled-back failed)") did not boot; $(describe "$(sget rolled-back restored)") runs instead ($(sget rolled-back time))"
    fi
    return 0
}

cmd_note() {
    local f
    if [[ -r $STATE/rolled-back ]]; then
        f=$(sget rolled-back failed)
        echo "nixith: warning: $(describe "$f") did not boot, so the boot loader went back to $(describe "$(sget rolled-back restored)") ($(sget rolled-back time))." >&2
        echo "nixith: (see \`nixith boot-status\`; \`nixith boot-status --ack\` forgets this.)" >&2
    fi
    if [[ -r $STATE/trial ]]; then
        echo "nixith: $(describe "$(sget trial toplevel)") is on trial: it is the default for good once it has booted." >&2
    fi
    return 0
}

cmd_ack() { rm -f "$STATE/rolled-back"; }

cmd=${1:-status}
[[ $# -gt 0 ]] && shift
case $cmd in
    arm) cmd_arm "$@" ;;
    good) cmd_good "$@" ;;
    status) cmd_status "$@" ;;
    note) cmd_note "$@" ;;
    ack) cmd_ack "$@" ;;
    *)
        echo "Usage: nixith-boot-assess arm TOPLEVEL | good | status | note | ack" >&2
        exit 1
        ;;
esac
