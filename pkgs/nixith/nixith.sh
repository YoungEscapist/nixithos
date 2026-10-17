#!@shell@
# nixith: builds and switches NixithOS systems, the whole configuration or
# only parts of it; and the other tools of the system under one name.  See
# `nixith help` and ../../lib/nixith.nix.
set -euo pipefail

export PATH=@path@:$PATH
tree=@tree@
nixpkgs=@nixpkgs@
profiles=/nix/var/nix/profiles

die() {
    echo "nixith: $*" >&2
    exit 1
}
say() { echo "$*" >&2; }

usage() {
    cat << 'EOF'
Usage: nixith <command> [options]

Building the system:
  switch            build it, make it the boot default and switch to it
  boot              build it and make it the boot default
  test              build it and switch to it, not for the next boot
  build             build it (./result)
  dry-build         show what would be built
  dry-activate      build it and show what switching would do
  build-vm          a script that boots it in QEMU (./result/bin/run-*-vm)
  rollback          switch back to the previous generation

  --only PATH       build only this part of the configuration: an option or
                    a group of them (services.nginx, environment.systemPackages,
                    users.users).  Repeatable, or comma separated.  Everything
                    else stays as in the running system.
  --flake REF[#NAME]  a flake (nixithConfigurations.NAME, or
                    nixosConfigurations.NAME), NAME = host name by default
  --file FILE       the configuration (default /etc/nixith/configuration.nix)
  --install-bootloader, --profile-name NAME, --specialisation NAME,
  --upgrade (update the channels first)
  Nix's options are passed on: -I, -j, --cores, --option, --show-trace,
  --keep-going, --fallback, -v, -L...

The rest:
  parts             what the running system was built from, part by part
  generations       the generations of the system
  install           install the configuration in /mnt (nixos-install; --root DIR)
  generate-config   write configuration.nix and hardware-configuration.nix
                    to /etc/nixith (--root DIR, --dir DIR, --show-hardware-config)
  enter             a shell in the installed system (--root DIR)
  option NAME       the value of an option of the configuration
  version           the version of the running system (--json, --revision)
  edit              open the configuration in $EDITOR
EOF
}

# The configuration file: /etc/nixith/configuration.nix, or that of a system
# installed before the rename.
config_file() {
    local root=${1:-}
    if [ -n "${NIXITH_CONFIG:-}" ]; then
        echo "$NIXITH_CONFIG"
    elif [ -e "$root/etc/nixith/configuration.nix" ] || [ ! -e "$root/etc/nixos/configuration.nix" ]; then
        echo "$root/etc/nixith/configuration.nix"
    else
        echo "$root/etc/nixos/configuration.nix"
    fi
}

# the flake to build by default: /etc/nixith/flake.nix, if there is one
default_flake() {
    local root=${1:-}
    if [ -z "${NIXITH_CONFIG:-}" ] && [ -e "$root/etc/nixith/flake.nix" ]; then
        echo "$root/etc/nixith"
    fi
}

host_name() {
    local h
    h=$(cat /proc/sys/kernel/hostname 2> /dev/null || true)
    echo "${h:-nixith}"
}

# A flake reference as lib/nixith.nix takes it: with the name of the system
# (the host name by default), and a local directory as an absolute path:
flake_ref() {
    local ref=${1%%#*} name
    case $1 in
        *'#'*) name=${1#*#} ;;
        *) name=$(host_name) ;;
    esac
    case $ref in
        *:*) ;;
        *) ref="path:$(realpath "$ref")" ;;
    esac
    echo "$ref#$name"
}

build_system() {
    local action=$1
    shift
    local only=() file="" flake="" profile=system specialisation=""
    local installBootloader="" upgrade="" rollback=""
    local nixArgs=()
    while [ $# -gt 0 ]; do
        case $1 in
            --only)
                [ $# -ge 2 ] || die "--only wants an option path"
                only+=("$2")
                shift 2
                ;;
            --only=*)
                only+=("${1#--only=}")
                shift
                ;;
            --flake)
                [ $# -ge 2 ] || die "--flake wants a flake"
                flake=$2
                shift 2
                ;;
            --flake=*)
                flake=${1#--flake=}
                shift
                ;;
            --no-flake)
                flake=-
                shift
                ;;
            --file | -f)
                file=$2
                shift 2
                ;;
            --profile-name | -p)
                profile=system-profiles/$2
                shift 2
                ;;
            --specialisation | -c)
                specialisation=$2
                shift 2
                ;;
            --install-bootloader)
                installBootloader=1
                shift
                ;;
            --upgrade | --upgrade-all)
                upgrade=1
                shift
                ;;
            --rollback)
                rollback=1
                shift
                ;;
            --fast | --no-build-nix)
                shift
                ;;
            -I | -j | --max-jobs | --cores | --builders | --log-format | --store)
                nixArgs+=("$1" "$2")
                shift 2
                ;;
            --option | --arg | --argstr)
                nixArgs+=("$1" "$2" "$3")
                shift 3
                ;;
            -*)
                nixArgs+=("$1")
                shift
                ;;
            *)
                die "unexpected argument: $1 (see nixith help)"
                ;;
        esac
    done

    case $action in
        switch | boot | test | dry-activate | rollback)
            [ "$(id -u)" = 0 ] || die "$action changes the system: run it as root (sudo nixith $action)"
            ;;
    esac

    local profilePath=$profiles/$profile
    [ "$profile" = system ] || mkdir -p "$profiles/system-profiles"

    if [ "$action" = rollback ]; then
        action=switch
        rollback=1
    fi

    local out
    if [ -n "$rollback" ]; then
        case $action in
            switch | boot)
                nix-env -p "$profilePath" --rollback
                out=$(readlink -f "$profilePath")
                ;;
            test | build)
                local gen
                gen=$(nix-env -p "$profilePath" --list-generations | tail -2 | head -1 | awk '{print $1}')
                [ "$(nix-env -p "$profilePath" --list-generations | wc -l)" -ge 2 ] || gen=""
                [ -n "$gen" ] || die "there is no previous generation"
                out=$(readlink -f "$profilePath-$gen-link")
                ;;
            *) die "--rollback goes with switch, boot, test or build" ;;
        esac
    else
        if [ -n "$upgrade" ]; then
            [ "$(id -u)" = 0 ] || die "--upgrade updates root's channels: run as root"
            nix-channel --update
        fi

        if [ -z "$flake" ] && [ -z "$file" ]; then
            flake=$(default_flake)
        fi
        [ "$flake" = - ] && flake=""

        local args=(--arg tree "$tree" --arg nixpkgs "$nixpkgs")
        local what
        if [ -n "$flake" ]; then
            flake=$(flake_ref "$flake")
            args+=(--argstr flake "$flake")
            what="the flake $flake"
            nixArgs+=(--extra-experimental-features "nix-command flakes")
        else
            [ -n "$file" ] || file=$(config_file)
            [ -e "$file" ] || die "no configuration at $file (nixith generate-config writes one)"
            file=$(realpath "$file")
            args+=(--argstr configuration "$file")
            what=$file
            case $file in /etc/nixos/*)
                say "(the configuration is still in /etc/nixos; NixithOS keeps it in /etc/nixith)" ;;
            esac
        fi

        if [ ${#only[@]} -gt 0 ]; then
            local current=/run/current-system
            [ "$profile" = system ] || current=$profilePath
            [ -e "$current/nixith/source.json" ] || die "the running system does not say what it was built from (it was not built by nixith): build it whole once with \`nixith $action\`, then parts of it"
            local list
            list=$(IFS=,; echo "${only[*]}")
            args+=(--argstr only "$list" --arg previous "$(readlink -f "$current/nixith/source.json")")
            say "building only ${list//,/, } of $what; the rest as in $(readlink -f "$current")..."
        else
            say "building the system configuration ($what)..."
        fi

        case $action in
            dry-build)
                nix-build "$tree/lib/nixith.nix" -A system --dry-run "${args[@]}" "${nixArgs[@]}"
                return
                ;;
            build-vm | build-vm-with-bootloader)
                local attr=config.system.build.vm
                [ "$action" = build-vm ] || attr=config.system.build.vmWithBootLoader
                out=$(nix-build "$tree/lib/nixith.nix" -A "$attr" "${args[@]}" "${nixArgs[@]}")
                say "Done.  The virtual machine can be started by running $(echo "$out"/bin/run-*-vm)"
                return
                ;;
            build)
                out=$(nix-build "$tree/lib/nixith.nix" -A system "${args[@]}" "${nixArgs[@]}")
                ;;
            *)
                out=$(nix-build --no-out-link "$tree/lib/nixith.nix" -A system "${args[@]}" "${nixArgs[@]}")
                ;;
        esac
        [ -n "$out" ] || die "the build gave no system"
        out=${out##*$'\n'}
    fi

    if [ -n "$specialisation" ]; then
        [ -d "$out/specialisation/$specialisation" ] || die "the system has no specialisation $specialisation"
    fi
    local target=$out${specialisation:+/specialisation/$specialisation}

    case $action in
        build)
            [ -n "$rollback" ] && echo "$out"
            ;;
        switch | boot)
            if [ -z "$rollback" ]; then
                nix-env -p "$profilePath" --set "$out"
            fi
            if [ -n "$installBootloader" ]; then export NIXOS_INSTALL_BOOTLOADER=1; fi
            "$target/bin/switch-to-configuration" "$action"
            ;;
        test | dry-activate)
            "$target/bin/switch-to-configuration" "$action"
            ;;
    esac
}

# what the running system was built from
parts() {
    local sys=${1:-/run/current-system}
    local src=$sys/nixith/source.json
    if [ ! -e "$src" ]; then
        echo "$(readlink -f "$sys") was not built by nixith: it does not say what it was built from."
        return
    fi
    jq -r '
      def what: if .kind == "file" then "\(.config)/\(.file)" else "\(.ref)#\(.name)" end;
      "system:  \(input_filename | sub("/nixith/source.json$"; ""))",
      "base:    \(.base | what)",
      (if (.layers | length) == 0 then "         (built whole: no part rebuilt on its own since)"
       else (.layers | to_entries[] |
         "part \(.key + 1):  \(.value.only | join(", "))\n         from \(.value.source | what)") end)
    ' "$(readlink -f "$src")" | sed "1s|.*|system:  $(readlink -f "$sys")|"
}

install_system() {
    local root=/mnt flake="" file="" args=()
    while [ $# -gt 0 ]; do
        case $1 in
            --root)
                root=$2
                shift 2
                ;;
            --flake)
                flake=$2
                shift 2
                ;;
            --file | -f)
                file=$2
                shift 2
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done
    [ "$(id -u)" = 0 ] || die "install wants root (sudo nixith install)"
    root=$(realpath "$root")
    [ -n "$flake" ] || [ -n "$file" ] || flake=$(default_flake "$root")

    # nixos-install builds `config.system.build.toplevel` of a file in the
    # store of the new system: here, lib/nixith.nix of the configuration, so
    # that the system says what it was built from.
    local tmp
    tmp=$(mktemp -d)
    # the path goes in now: the trap runs at exit, after this function's
    # locals are gone (and with set -u an unset $tmp fails the install)
    trap "rm -rf $(printf %q "$tmp")" EXIT
    {
        echo "import $tree/lib/nixith.nix {"
        echo "  tree = $tree;"
        echo "  nixpkgs = $nixpkgs;"
        echo "  copySources = true;"
        if [ -n "$flake" ]; then
            flake=$(flake_ref "$flake")
            echo "  flake = \"$flake\";"
        else
            [ -n "$file" ] || file=$(config_file "$root")
            [ -e "$file" ] || die "no configuration at $file (nixith generate-config --root $root writes one)"
            echo "  configuration = \"$(realpath "$file")\";"
        fi
        echo "}"
    } > "$tmp/system.nix"
    if [ -n "$flake" ]; then
        args+=(--option extra-experimental-features "nix-command flakes")
    fi
    nixos-install --root "$root" --file "$tmp/system.nix" "${args[@]}"
}

generate_config() {
    local root="" dir="" args=()
    while [ $# -gt 0 ]; do
        case $1 in
            --root)
                root=$2
                args+=("$1" "$2")
                shift 2
                ;;
            --dir)
                dir=$2
                shift 2
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done
    if [ -z "$dir" ]; then
        root=${root%/}
        dir=$root/etc/nixith
    fi
    nixos-generate-config --dir "$dir" "${args[@]}"
}

# As `nix-env --list-generations`, but from the links themselves: nix-env
# takes the profile's lock to read it, and a user may not.
generations() {
    local link current n
    current=$(readlink "$profiles/system")
    for link in "$profiles"/system-*-link; do
        [ -L "$link" ] || continue
        n=${link##*/system-}
        n=${n%-link}
        # (the link's own time: what it points to in the store is from 1970)
        printf '%s\t%s%s\n' "$n" "$(stat -c %y "$link" | cut -d. -f1)" \
            "$([ "${link##*/}" = "$current" ] && echo '   (current)')"
    done | sort -n | awk -F'\t' '{ printf "%4s   %s\n", $1, $2 }'
}

version() {
    local sys=/run/current-system
    case ${1:-} in
        --json)
            jq -n --arg v "$(cat $sys/nixos-version)" --arg r "$(cat "$nixpkgs/.git-revision" 2> /dev/null)" \
                '{nixithVersion: $v} + (if $r == "" then {} else {nixpkgsRevision: $r} end)'
            ;;
        --revision)
            cat "$nixpkgs/.git-revision" 2> /dev/null || die "the nixpkgs of this system has no revision"
            ;;
        --configuration-revision)
            cat $sys/configuration-revision 2> /dev/null || true
            ;;
        *)
            . /etc/os-release
            echo "${VERSION:-$(cat $sys/nixos-version)}"
            ;;
    esac
}

# (also as nixith-install, nixith-generate-config, ...: nixith install, ...)
case ${0##*/} in
    nixith-*)
        command=${0##*/}
        command=${command#nixith-}
        ;;
    *)
        command=${1:-help}
        [ $# -gt 0 ] && shift
        ;;
esac
# (nixith-rebuild switch = nixith switch)
if [ "$command" = rebuild ]; then
    command=${1:-help}
    [ $# -gt 0 ] && shift
fi
case $command in
    switch | boot | test | build | dry-build | dry-run | dry-activate | build-vm | build-vm-with-bootloader | rollback)
        [ "$command" = dry-run ] && command=dry-build
        build_system "$command" "$@"
        ;;
    parts) parts "$@" ;;
    generations | list-generations)
        generations "$@"
        ;;
    install) install_system "$@" ;;
    generate-config) generate_config "$@" ;;
    enter) exec nixos-enter "$@" ;;
    option)
        file=$(config_file)
        exec nixos-option -I "nixos-config=$file" "$@"
        ;;
    version) version "$@" ;;
    edit)
        file=$(config_file)
        exec "${EDITOR:-nano}" "$file"
        ;;
    help | -h | --help) usage ;;
    *)
        usage >&2
        exit 1
        ;;
esac
