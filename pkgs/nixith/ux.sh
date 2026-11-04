# nixith: what the build tools do not tell, in the words of the units:
#
#   nixith diff      what switching to a system would do to the units
#   nixith why UNIT  why a unit is (not) running, and what became of it
#
# Sourced by nixith.sh (which has die, say and the PATH).  Both read the
# database of the service manager (the index and deps.tsv unitc writes), so
# they say the same under s6 and under dinit.

# colours, when the output is a terminal
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    c_b=$'\e[1m' c_d=$'\e[2m' c_r=$'\e[31m' c_g=$'\e[32m' c_y=$'\e[33m' c_0=$'\e[0m'
else
    c_b="" c_d="" c_r="" c_g="" c_y="" c_0=""
fi

# --------------------------------------------------------------------------
# nixith diff

# system_diff NEW [CURRENT]: the units' plan (switch-to-configuration plan),
# then the packages (nix store diff-closures)
system_diff() {
    local new=$1 cur=${2:-/run/current-system} full=${3:-}
    local sw=$new/bin/switch-to-configuration
    [ -x "$sw" ] || die "$new is not a system (no bin/switch-to-configuration)"

    echo "${c_b}from${c_0} $(readlink -f "$cur")"
    echo "${c_b}to${c_0}   $(readlink -f "$new")"
    if [ "$(readlink -f "$cur")" = "$(readlink -f "$new")" ]; then
        echo
        echo "It is the system that runs: nothing would change."
        return 0
    fi

    local plan
    if ! plan=$("$sw" plan); then
        die "could not compare the units with the running ones (as root: sudo nixith diff)"
    fi

    echo
    echo "${c_b}Services${c_0}"
    local note
    note=$(awk -F'\t' '$1 == "#note" { print $2 }' <<< "$plan")
    if [ -n "$note" ]; then
        echo "  $note"
    else
        local kind title colour rows n shown=0
        for kind in stop stop-start restart rerun reload start keep; do
            rows=$(awk -F'\t' -v k="$kind" '$1 == k' <<< "$plan")
            [ -n "$rows" ] || continue
            n=$(wc -l <<< "$rows")
            case $kind in
                stop) title="will be stopped" colour=$c_r ;;
                stop-start) title="will be stopped, then started again (stopIfChanged)" colour=$c_y ;;
                restart) title="will be restarted" colour=$c_y ;;
                rerun) title="will run again (jobs that run once at boot)" colour=$c_y ;;
                reload) title="will be reloaded (reloadIfChanged)" colour=$c_y ;;
                start) title="will be started" colour=$c_g ;;
                keep) title="changed, but left running as they are (restartIfChanged = false)" colour=$c_d ;;
            esac
            echo "  ${colour}${title} ($n)${c_0}"
            awk -F'\t' '{ u[NR] = $2; r[NR] = $3; if (length($2) > w) w = length($2) }
                END { for (i = 1; i <= NR; i++) printf "    %-*s  %s\n", w, u[i], r[i] }' <<< "$rows"
            shown=$((shown + n))
        done
        local same idle
        same=$(awk -F'\t' '$1 == "same" { print $2 }' <<< "$plan")
        idle=$(awk -F'\t' '$1 == "idle" { print $2 }' <<< "$plan")
        [ "$shown" -gt 0 ] || echo "  no unit would be touched"
        echo "  ${c_d}not touched: ${same:-0} unchanged units${idle:+, $idle changed but not running}${c_0}"
    fi
    echo "  ${c_d}(the activation script also lays down /etc, users and groups: not shown)${c_0}"

    echo
    echo "${c_b}Packages${c_0}"
    local pk
    pk=$(nix --extra-experimental-features nix-command store diff-closures "$cur" "$new" 2> /dev/null | sed 's/\x1b\[[0-9;]*m//g') || pk=""
    if [ -z "$pk" ]; then
        echo "  no package changes"
    else
        local total
        total=$(wc -l <<< "$pk")
        if [ -z "$full" ] && [ "$total" -gt 40 ]; then
            head -n 40 <<< "$pk" | sed 's/^/  /'
            echo "  ${c_d}... and $((total - 40)) more (nixith diff --full)${c_0}"
        else
            sed 's/^/  /' <<< "$pk"
        fi
        echo "  ${c_d}$total package lines changed${c_0}"
    fi
}

# --------------------------------------------------------------------------
# nixith why

# the database the service manager runs on, and which manager it is
live_db() {
    WHY_INIT=none
    if [ -n "${NIXITH_DB:-}" ]; then
        # (a database to look in, not the live one: for tests)
        WHY_DB=$NIXITH_DB
        WHY_INIT=$(if [ -L /run/units/.db ]; then echo dinit; else echo s6; fi)
    elif [ -L /run/units/.db ] && [ ! -e /run/s6-rc/compiled ]; then
        WHY_INIT=dinit
        WHY_DB=$(readlink -f /run/units/.db)
    elif [ -e /run/s6-rc/compiled ]; then
        WHY_INIT=s6
        WHY_DB=$(readlink -f /run/s6-rc/compiled)
        WHY_DB=${WHY_DB%/*}
    else
        WHY_DB=$(readlink -f /run/current-system/s6-db 2> /dev/null) || WHY_DB=
    fi
    [ -n "$WHY_DB" ] && [ -r "$WHY_DB/index.tsv" ] || die "no service database found (is the system running on s6 or dinit?)"
}

# dname ATOM -> DN, the name dinit knows it by (unitc's names)
dname() {
    DN=${1//@/＠}
    DN=${DN//\\/∖}
    DN=${DN//:/꞉}
}

# the name of a signal
signame() { kill -l "$1" 2> /dev/null || echo "$1"; }

why_unit() {
    local name=${1:-}
    [ -n "$name" ] || die "why: which unit? (nixith why nginx.service)"
    live_db
    local db=$WHY_DB

    # the unit: the name as given, its .service, an alias
    local unit="" cand
    for cand in "$name" "$name.service"; do
        if awk -F'\t' -v u="$cand" '$1 == u && $2 != "alias" { f = 1 } END { exit !f }' "$db/index.tsv"; then
            unit=$cand
            break
        fi
        cand=$(awk -F'\t' -v u="$cand" '$1 == u && $2 == "alias" { print $3; exit }' "$db/index.tsv")
        if [ -n "$cand" ]; then
            unit=$cand
            break
        fi
    done
    if [ -z "$unit" ]; then
        echo "nixith: no unit $name in the running system's database." >&2
        local near
        near=$(awk -F'\t' -v u="${name%.service}" 'index($1, u) { print $1 }' "$db/index.tsv" | head -n 8)
        [ -z "$near" ] || { echo "Similar:" >&2; sed 's/^/  /' <<< "$near" >&2; }
        return 1
    fi

    local kind type rank boot atom atoms
    IFS=$'\t' read -r _ kind type rank boot atom atoms _ < <(awk -F'\t' -v u="$unit" '$1 == u && $2 != "alias"' "$db/index.tsv")
    local desc
    desc=$(sed -n 's/^Description=//p' "$db/units/$unit" 2> /dev/null | tail -n1)

    echo "${c_b}$unit${c_0}${desc:+ - $desc}"

    # ---- state
    local show="" active="" sub="" pid="" result="" status="" nrestarts="" since=""
    show=$(systemctl show "$unit" 2> /dev/null || true)
    prop() { sed -n "s/^$1=//p" <<< "$show" | head -n1; }
    active=$(prop ActiveState) sub=$(prop SubState) pid=$(prop MainPID)
    result=$(prop Result) status=$(prop ExecMainStatus) nrestarts=$(prop NRestarts)
    if [ "$active" = active ]; then since=$(prop ActiveEnterTimestamp); else since=$(prop InactiveEnterTimestamp); fi
    local colour=$c_d
    case $active in active) colour=$c_g ;; failed) colour=$c_r ;; activating | deactivating) colour=$c_y ;; esac
    echo
    echo "${c_b}State${c_0}   ${colour}${active:-unknown} (${sub:-?})${c_0}${since:+ since $since}"
    [ -z "$pid" ] || [ "$pid" = 0 ] || echo "        main process $pid ($(tr '\0' ' ' < "/proc/$pid/cmdline" 2> /dev/null | cut -c1-70))"
    [ -z "$nrestarts" ] || [ "$nrestarts" = 0 ] || echo "        restarted $nrestarts times by the supervisor"
    if [ "$active" = failed ] || { [ "$result" != success ] && [ -n "$result" ]; }; then
        local ex=/run/units/$unit/exit code sig res
        if [ -r "$ex" ]; then
            read -r code sig res < "$ex" || true
            if [ "${code:-}" = 256 ]; then
                echo "        ${c_r}killed by signal $sig ($(signame "$sig"))${c_0}, result: ${res:-$result}"
            else
                echo "        ${c_r}exited with status ${code:-$status}${c_0}, result: ${res:-$result}"
            fi
        else
            # (a job that runs once leaves no exit file; its log has the status)
            local st
            st=$( { tail -n 200 "/var/log/s6/$atom/current" 2> /dev/null; tail -n 20 "/run/units/$unit/journal" 2> /dev/null; } |
                sed -n 's/.*\(FAILED (status \|failed with status \)\([0-9][0-9]*\).*/\2/p' | tail -n1)
            if [ -n "$st" ]; then
                echo "        ${c_r}exited with status $st${c_0}, result: ${result:-failed}"
            else
                echo "        result: ${result:-failed}"
            fi
        fi
    fi

    # ---- what the manager says
    echo
    echo "${c_b}Manager${c_0} ${WHY_INIT} (database $db)"
    local a
    for a in $atoms; do
        case $a in *-log | *-hooks) continue ;; esac
        if [ "$WHY_INIT" = dinit ]; then
            dname "$a"
            "$dinitctl" -p /run/dinitctl status "$DN" 2>&1 | sed "s|^|        |" || true
        elif [ "$WHY_INIT" = s6 ]; then
            if [ -d "/run/service/$a" ]; then
                echo "        $a: $("$s6_svstat" "/run/service/$a" 2>&1)"
            else
                local upnow
                upnow=$("$s6_rc" -a list 2> /dev/null || true)
                echo "        $a: a job that runs to completion, no process to supervise; s6-rc has it $(grep -qx -- "$a" <<< "$upnow" && echo up || echo down)"
            fi
        fi
    done
    if [ "$WHY_INIT" = dinit ] && [ -r "/run/units/.sv/$atom" ]; then
        echo "        supervisor: $(cat "/run/units/.sv/$atom")  (up ready pid want supervisor-pid phase)"
    fi

    # ---- who pulls it in
    if [ ! -r "$db/deps.tsv" ]; then
        echo
        echo "(this database has no deps.tsv, the dependencies are not known: switch to a system built by this nixith)"
    else
        why_chain "$unit" "$db"
    fi

    # ---- last of its log
    local log=/var/log/s6/$atom/current
    echo
    if [ -r "$log" ]; then
        echo "${c_b}Log${c_0} $log"
        tail -n 10 "$log" | sed 's/^/        /'
    elif [ -e "$log" ]; then
        echo "${c_b}Log${c_0} $log is not readable (as root: sudo nixith why $name)"
    else
        echo "${c_b}Log${c_0} none ($log does not exist: the unit never ran, or logs elsewhere)"
    fi
    if [ -r "/run/units/$unit/journal" ]; then
        echo
        echo "${c_b}Events${c_0}"
        tail -n 6 "/run/units/$unit/journal" | sed 's/^/        /'
    fi
}

# why_chain UNIT DB: the shortest chain of Wants/Requires from the default
# target to the unit, who else pulls it, what it pulls and how those are
why_chain() {
    local unit=$1 db=$2
    local default
    default=$(jq -r '.default' "$db/manifest.json" 2> /dev/null || echo default.target)

    local -A REQ=() WANT=() BIND=() BY=() PARENT=() PKIND=() ST=()
    local u r w b x
    while IFS=$'\t' read -r u r w b; do
        REQ[$u]=$r WANT[$u]=$w BIND[$u]=$b
        for x in $r; do BY[$x]+="$u:requires "; done
        for x in $w; do BY[$x]+="$u:wants "; done
        for x in $b; do BY[$x]+="$u:binds "; done
    done < "$db/deps.tsv"

    # breadth first from the default target
    local -a queue=("$default")
    local head=0 cur kindname
    PARENT[$default]=""
    while [ $head -lt ${#queue[@]} ]; do
        cur=${queue[$head]}
        head=$((head + 1))
        for kindname in requires wants binds; do
            case $kindname in
                requires) set -- ${REQ[$cur]-} ;;
                wants) set -- ${WANT[$cur]-} ;;
                binds) set -- ${BIND[$cur]-} ;;
            esac
            for x in "$@"; do
                [ -z "${PARENT[$x]+set}" ] || continue
                PARENT[$x]=$cur PKIND[$x]=$kindname
                queue+=("$x")
            done
        done
    done

    # the state of every unit, for the lists below
    local line
    while read -r u _ x _; do ST[$u]=$x; done < <(systemctl list-units --all --no-legend 2> /dev/null || true)

    echo
    echo "${c_b}Why it is started${c_0}"
    local via=""
    if [ "$unit" = "$default" ] || [ -n "${PARENT[$unit]+set}" ]; then
        local -a chain=()
        cur=$unit
        while [ -n "$cur" ]; do
            chain=("$cur" "${chain[@]}")
            cur=${PARENT[$cur]-}
        done
        local i indent=""
        for ((i = 0; i < ${#chain[@]}; i++)); do
            cur=${chain[$i]}
            if [ $i -eq 0 ]; then
                echo "        $cur"
            else
                echo "        ${indent}└─ $cur ${c_d}(${PKIND[$cur]})${c_0}"
                indent+="   "
            fi
        done
    else
        # not downstream of the default target: activation by a socket, a
        # timer or a path unit that is?
        local base=${unit%.*} act
        for act in "$base.socket" "$base.timer" "$base.path"; do
            [ -n "${PARENT[$act]+set}" ] && via+="$act "
        done
        if [ -n "$via" ]; then
            echo "        not wanted by the default target ($default) itself, but started on demand by: $via"
            echo "        (which $default pulls in)"
        else
            echo "        ${c_y}$default does not pull it in${c_0}: it is not started at boot."
            echo "        It runs only when started by hand (systemctl start $unit), or by a unit that is started and wants it."
        fi
    fi

    # everyone that pulls it
    local by=${BY[$unit]-} p k
    if [ -n "$by" ]; then
        echo
        echo "${c_b}Pulled in by${c_0}"
        for x in $by; do
            p=${x%:*} k=${x##*:}
            if [ -n "${PARENT[$p]+set}" ] || [ "$p" = "$default" ]; then
                printf '        %-44s %-10s %s\n' "$p" "($k)" "${c_g}started at boot${c_0}"
            else
                printf '        %-44s %-10s %s\n' "$p" "($k)" "${c_d}not started at boot${c_0}"
            fi
        done | sort | head -n 20
    fi

    # what it pulls, with the state of those not in order
    local dep="" deps_n=0 bad=""
    for x in ${REQ[$unit]-} ${BIND[$unit]-} ${WANT[$unit]-}; do
        deps_n=$((deps_n + 1))
        case ${ST[$x]-inactive} in failed) bad+="$x (failed) " ;; esac
    done
    if [ -n "$bad" ]; then
        echo
        echo "${c_r}Failed dependencies${c_0}: $bad"
    fi
    if [ $deps_n -gt 0 ]; then
        echo
        echo "${c_b}Requires${c_0} ${REQ[$unit]-}"
        [ -z "${BIND[$unit]-}" ] || echo "${c_b}Binds to${c_0} ${BIND[$unit]}"
        local wl=${WANT[$unit]-}
        [ -z "$wl" ] || echo "${c_b}Wants${c_0}   $(tr ' ' '\n' <<< "$wl" | head -n 12 | paste -sd' ' -)$([ "$(wc -w <<< "$wl")" -gt 12 ] && echo ' ...')"
    fi
}
