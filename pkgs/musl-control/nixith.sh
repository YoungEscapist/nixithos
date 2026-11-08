#!@shell@
set -eu

usage() {
    @busybox@ cat <<'EOF'
Usage: nixith COMMAND [ARGUMENTS]
  help, --help             Show this help
  version, --version       Show strict-profile control version
  services                 List dinit services and their state
  status SERVICE           Show one service's state
  start SERVICE            Start a service and its dependencies
  stop SERVICE             Stop a service
  restart SERVICE          Restart a service
  logs SERVICE             Print /var/log/SERVICE.log if present
  poweroff                 Ask dinit PID 1 to shut down and power off
  reboot                   Ask dinit PID 1 to shut down and reboot
  switch SYSTEM_PATH      Activate an already deployed store generation
  build, install          Unsupported in the minimal runtime
EOF
}
fail() { printf '%s\n' "nixith: $*" >&2; exit 2; }
service_arg() {
    [ "$#" -eq 1 ] || fail 'exactly one service name is required'
    case "$1" in ''|*[!a-zA-Z0-9_.@-]*|-*) fail 'invalid service name';; esac
}
switch_system() {
    [ "$#" -eq 1 ] || fail 'switch requires one deployed system path'
    case "$1" in /nix/store/*) ;; *) fail 'system path must be an absolute /nix/store path';; esac
    target=$(@busybox@ readlink -f "$1") || fail 'cannot resolve system path'
    case "$target" in /nix/store/*/*) fail 'system path must name a store output';; /nix/store/*) ;; *) fail 'system resolves outside the store';; esac
    [ "$(@busybox@ cat "$target/etc/nixith-musl" 2>/dev/null)" = 1 ] || fail 'generation requires strict musl schema 1 in etc/nixith-musl'
    [ -d "$target/etc/dinit.d" ] || fail 'generation has no etc/dinit.d'
    [ -L /etc/dinit.d ] || fail '/etc/dinit.d must be a mutable symlink'
    [ -L /run/current-system ] || fail '/run/current-system must be a mutable symlink'
    [ -L /nix/var/nix/profiles/system ] || fail '/nix/var/nix/profiles/system must be a mutable symlink'
    if [ -e /nix/var/nix/profiles/system-previous ] && [ ! -L /nix/var/nix/profiles/system-previous ]; then
        fail '/nix/var/nix/profiles/system-previous must be absent or a mutable symlink'
    fi
    [ "$(@busybox@ id -u)" -eq 0 ] || fail 'switch requires root'
    @busybox@ mkdir /run/nixith-switch.lock 2>/dev/null || fail 'another switch is in progress (lock: /run/nixith-switch.lock)'
    trap '@busybox@ rm -f /etc/.nixith-dinit.$$ /etc/.nixith-hostname.$$ /etc/.nixith-os-release.$$ /etc/unit-runtime/.nixith-services.$$ /run/.nixith-current.$$ /nix/var/nix/profiles/.nixith-system.$$ /nix/var/nix/profiles/.nixith-previous.$$; @busybox@ rmdir /run/nixith-switch.lock' EXIT
    trap 'exit 1' HUP INT TERM
    old_services=$(@busybox@ readlink -f /etc/dinit.d)
    old_system=$(@busybox@ readlink -f /run/current-system)
    old_profile=$(@busybox@ readlink -f /nix/var/nix/profiles/system)
    new_services=$(@busybox@ readlink -f "$target/etc/dinit.d")
    @dinitcheck@ --system -d "$new_services" boot || fail 'new service graph failed validation'
    @dinitctl@ --system status boot >/dev/null || fail 'cannot contact dinit boot service'
    # Prepare both links before altering the running service graph. Each rename
    # is atomic; the pair and service transitions are not a transaction.
    @busybox@ ln -s "$new_services" /etc/.nixith-dinit.$$
    @busybox@ ln -s "$target" /run/.nixith-current.$$
    @busybox@ ln -s "$target" /nix/var/nix/profiles/.nixith-system.$$
    if [ "$target" != "$old_system" ]; then
        @busybox@ ln -s "$old_system" /nix/var/nix/profiles/.nixith-previous.$$
    fi
    if [ -L /etc/unit-runtime/services ] && [ -d "$target/etc/unit-runtime/services" ]; then
        @busybox@ ln -s "$target/etc/unit-runtime/services" /etc/unit-runtime/.nixith-services.$$
    fi
    @busybox@ mv -Tf /etc/.nixith-dinit.$$ /etc/dinit.d
    if ! @busybox@ mv -Tf /nix/var/nix/profiles/.nixith-system.$$ /nix/var/nix/profiles/system; then
        @busybox@ ln -s "$old_services" /etc/.nixith-dinit.$$
        @busybox@ mv -Tf /etc/.nixith-dinit.$$ /etc/dinit.d
        fail 'could not publish persistent profile; restored service-directory link'
    fi
    if ! @busybox@ mv -Tf /run/.nixith-current.$$ /run/current-system; then
        @busybox@ ln -s "$old_services" /etc/.nixith-dinit.$$
        @busybox@ mv -Tf /etc/.nixith-dinit.$$ /etc/dinit.d
        @busybox@ ln -s "$old_profile" /nix/var/nix/profiles/.nixith-system.$$
        @busybox@ mv -Tf /nix/var/nix/profiles/.nixith-system.$$ /nix/var/nix/profiles/system
        fail 'could not publish current-system; restored service-directory and persistent profile links'
    fi
    if [ -L /etc/unit-runtime/.nixith-services.$$ ]; then
        @busybox@ mv -Tf /etc/unit-runtime/.nixith-services.$$ /etc/unit-runtime/services ||
            fail "activation partially failed while updating unit-runtime; links name $target; previous generation $old_system"
    fi
    # Keep unchanged running services alive while boot's dependency references
    # are removed. In particular, killing __console would kill this caller.
    # Remember existing explicit activations rather than clearing them later.
    switch_failed=0
    held_services=
    for file in "$old_services"/*; do
        [ -f "$file" ] || continue
        name=${file##*/}
        [ "$name" != boot ] || continue
        if [ -f "$new_services/$name" ] && @busybox@ cmp -s "$file" "$new_services/$name" &&
           @dinitctl@ --system is-started "$name" >/dev/null 2>&1; then
            state=$(@dinitctl@ --system status "$name") || fail "activation partially failed querying $name; links name $target"
            case "$state" in
                *'Activation: explicitly started'*) ;;
                *'Activation: start due to dependent(s)'*)
                    @dinitctl@ --system start "$name" || fail "activation partially failed retaining $name; links name $target"
                    held_services="$held_services $name"
                    ;;
                *) fail "activation partially failed: unknown activation state for $name; refusing to stop boot; links name $target" ;;
            esac
        fi
    done
    for name in hostname os-release; do
        if [ -f "$target/etc/$name" ]; then
            if @busybox@ cp "$target/etc/$name" "/etc/.nixith-$name.$$" &&
               @busybox@ mv -Tf "/etc/.nixith-$name.$$" "/etc/$name"; then
                :
            else
                switch_failed=1
            fi
        fi
    done
    if [ -f /etc/hostname ]; then
        @busybox@ hostname -F /etc/hostname || switch_failed=1
    fi
    @dinitctl@ --system stop boot || switch_failed=1
    removed_services=
    for file in "$old_services"/*; do
        [ -f "$file" ] || continue
        name=${file##*/}
        [ "$name" != boot ] || continue
        if [ ! -f "$new_services/$name" ] || ! @busybox@ cmp -s "$file" "$new_services/$name"; then
            if @dinitctl@ --system status "$name" >/dev/null 2>&1; then
                @dinitctl@ --system stop --force "$name" || switch_failed=1
                if [ -f "$new_services/$name" ]; then
                    @dinitctl@ --system reload "$name" || switch_failed=1
                else
                    removed_services="$removed_services $name"
                fi
            fi
        fi
    done
    @dinitctl@ --system reload boot || switch_failed=1
    # Old boot and changed service definitions no longer retain removed graph
    # edges. Unload dependents before dependencies, retrying when needed.
    while [ -n "$removed_services" ]; do
        remaining_services=
        unloaded=0
        for name in $removed_services; do
            if @dinitctl@ --system unload "$name" >/dev/null 2>&1; then
                unloaded=1
            else
                remaining_services="$remaining_services $name"
            fi
        done
        if [ "$unloaded" -eq 0 ]; then
            for name in $remaining_services; do
                @dinitctl@ --system unload "$name" || switch_failed=1
            done
            break
        fi
        removed_services=$remaining_services
    done
    if @dinitctl@ --system start boot; then
        # release waits for STOPPED by default even when active dependents
        # keep a service running; --no-wait only clears our temporary mark.
        for name in $held_services; do
            @dinitctl@ --system release --no-wait "$name" || switch_failed=1
        done
    else
        switch_failed=1
    fi
    if [ "$switch_failed" -ne 0 ]; then
        fail "activation partially failed; links name $target; previous generation $old_system; inspect services and switch explicitly to recover"
    fi
    if [ -L /nix/var/nix/profiles/.nixith-previous.$$ ]; then
        @busybox@ mv -Tf /nix/var/nix/profiles/.nixith-previous.$$ /nix/var/nix/profiles/system-previous ||
            fail "activation partially failed retaining rollback root; links name $target; previous generation $old_system"
    fi
    printf '%s\n' "Activated $target"
}
[ "$#" -gt 0 ] || { usage; exit 0; }
command=$1
shift
case "$command" in
    help|--help) [ "$#" -eq 0 ] || fail 'help takes no arguments'; usage ;;
    version|--version)
        [ "$#" -eq 0 ] || fail 'version takes no arguments'
        printf '%s\n' 'nixith strict-musl control 0.1.0'
        ;;
    services)
        [ "$#" -eq 0 ] || fail 'services takes no arguments'
        exec @dinitctl@ --system list
        ;;
    status|start|stop|restart)
        service_arg "$@"
        exec @dinitctl@ --system "$command" "$1"
        ;;
    logs)
        service_arg "$@"
        logfile=/var/log/$1.log
        [ -f "$logfile" ] || fail "no log file at $logfile (service may log to the console)"
        exec @busybox@ cat "$logfile"
        ;;
    poweroff|reboot)
        [ "$#" -eq 0 ] || fail "$command takes no arguments"
        if [ "$command" = reboot ]; then
            exec @shutdown@ -r
        else
            exec @shutdown@ -p
        fi
        ;;
    switch) switch_system "$@" ;;
    install)
        fail 'install runs on the build host: python3 scripts/deploy-musl.py ROOTFS MOUNTED_TARGET; see docs/musl-busybox.md'
        ;;
    build)
        fail "$command is not implemented in the strict runtime; build the strict system on a Nix host and deploy it explicitly"
        ;;
    *) fail "unknown command '$command' (try nixith help)" ;;
esac
