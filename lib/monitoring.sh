#!/usr/bin/env bash
# Globals are shared with resmon.sh; PREV_* are also accessed by name in track_alert.
# shellcheck disable=SC2034

# ==============================================================================
# GLOBAL CONFIGURATION & DEFAULTS
# ==============================================================================

initialise_settings() {
    CPU_WARN=70
    CPU_CRIT=90
    MEM_WARN=75
    MEM_CRIT=90
    SWAP_WARN=20
    SWAP_CRIT=50
    LOAD_WARN=1.0
    LOAD_CRIT=2.0
    INTERVAL=1
    COUNT=0

    CSV_FILE="resource_report.csv"
    CLEANUP_DONE=0

    # Alert State Tracking
    PREV_CPU_STAT="OK"
    PREV_MEM_STAT="OK"
    PREV_SWAP_STAT="OK"
    PREV_LOAD_STAT="OK"

    # Summary Statistics Counters
    SAMPLES_TAKEN=0
    PEAK_CPU=0.0
    PEAK_MEM=0.0
    PEAK_SWAP=0.0
    PEAK_LOAD=0.0

    CPU_WARN_SEC=0
    CPU_CRIT_SEC=0
    MEM_WARN_SEC=0
    MEM_CRIT_SEC=0
    SWAP_WARN_SEC=0
    SWAP_CRIT_SEC=0
    LOAD_WARN_SEC=0
    LOAD_CRIT_SEC=0
    CPU_CORE_PCT=()
    CPU_CORES_STAT=()
    PREV_CORE_STAT=()
    PEAK_CORE=()
    CORE_WARN_SEC=()
    CORE_CRIT_SEC=()
    TIMESTAMP=""
    SAMPLE_SECONDS=0
    STOP_REQUESTED=0
    SLEEP_PID=""
    LOCK_HELD=0
    LOCK_DIR=""
    SAMPLED_SECONDS=0
}

# ==============================================================================
# ARGUMENT PARSING & VALIDATION
# ==============================================================================

# Check if input is a valid non-negative integer or decimal
is_numeric() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

# Check if input is a positive integer (> 0)
is_positive_int() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --cpu-warn)
            [[ $# -lt 2 ]] && { echo "Error: --cpu-warn requires a value." >&2; exit 1; }
            CPU_WARN="$2"
            shift 2
            ;;
        --cpu-crit)
            [[ $# -lt 2 ]] && { echo "Error: --cpu-crit requires a value." >&2; exit 1; }
            CPU_CRIT="$2"
            shift 2
            ;;
        --mem-warn)
            [[ $# -lt 2 ]] && { echo "Error: --mem-warn requires a value." >&2; exit 1; }
            MEM_WARN="$2"
            shift 2
            ;;
        --mem-crit)
            [[ $# -lt 2 ]] && { echo "Error: --mem-crit requires a value." >&2; exit 1; }
            MEM_CRIT="$2"
            shift 2
            ;;
        --swap-warn)
            [[ $# -lt 2 ]] && { echo "Error: --swap-warn requires a value." >&2; exit 1; }
            SWAP_WARN="$2"
            shift 2
            ;;
        --swap-crit)
            [[ $# -lt 2 ]] && { echo "Error: --swap-crit requires a value." >&2; exit 1; }
            SWAP_CRIT="$2"
            shift 2
            ;;
        --load-warn)
            [[ $# -lt 2 ]] && { echo "Error: --load-warn requires a value." >&2; exit 1; }
            LOAD_WARN="$2"
            shift 2
            ;;
        --load-crit)
            [[ $# -lt 2 ]] && { echo "Error: --load-crit requires a value." >&2; exit 1; }
            LOAD_CRIT="$2"
            shift 2
            ;;
        --interval)
            [[ $# -lt 2 ]] && { echo "Error: --interval requires a value." >&2; exit 1; }
            INTERVAL="$2"
            shift 2
            ;;
        --count)
            [[ $# -lt 2 ]] && { echo "Error: --count requires a value." >&2; exit 1; }
            COUNT="$2"
            shift 2
            ;;
        --help)
            echo "Usage: ./resmon.sh [options]"
            echo "Options:"
            echo "  --interval N       Sampling interval in seconds (default: 1)"
            echo "  --count M          Number of samples to take, 0 for infinite (default: 0)"
            echo "  --cpu-warn X       CPU warning threshold percentage (default: 70)"
            echo "  --cpu-crit X       CPU critical threshold percentage (default: 90)"
            echo "  --mem-warn X       Memory warning threshold percentage (default: 75)"
            echo "  --mem-crit X       Memory critical threshold percentage (default: 90)"
            echo "  --swap-warn X      Swap warning threshold percentage (default: 20)"
            echo "  --swap-crit X      Swap critical threshold percentage (default: 50)"
            echo "  --load-warn X      Load warning threshold per core (default: 1.0)"
            echo "  --load-crit X      Load critical threshold per core (default: 2.0)"
            echo "  --csv FILE         Append CSV to FILE (default: resource_report.csv)"
            echo "Load thresholds in the table are per-core limits multiplied by core count."
            exit 0
            ;;
        --csv)
            if [[ $# -lt 2 || -z "$2" ]]; then
            echo "Error: --csv requires a file path." >&2
            exit 1
            fi
            CSV_FILE="$2"
            shift 2
            ;;
        *)
            echo "Error: Unknown argument '$1'" >&2
            exit 1
            ;;
        esac
    done
}

validate_arguments() {
    local val
    # awk for decimal comparisons (returns true if $1 < $2)
    is_less_than() {
        awk -v num1="$1" -v num2="$2" 'BEGIN { exit !(num1 < num2) }'
    }

    # 1. Ensure thresholds are non-negative numbers
    for val in "$CPU_WARN" "$CPU_CRIT" "$MEM_WARN" "$MEM_CRIT" "$SWAP_WARN" "$SWAP_CRIT" "$LOAD_WARN" "$LOAD_CRIT"; do
        if ! is_numeric "$val"; then
        echo "Error: Threshold '$val' must be a non-negative number." >&2
        exit 1
        fi
    done

    # 2. Validate interval (must be an integer > 0)
    if ! is_positive_int "$INTERVAL" || [[ ${#INTERVAL} -gt 5 ]] || ((INTERVAL > 86400)); then
        echo "Error: --interval must be a positive integer greater than 0." >&2
        exit 1
    fi

    # 3. Validate count (must be an integer >= 0)
    if [[ ! "$COUNT" =~ ^[0-9]+$ || ${#COUNT} -gt 7 ]]; then
        echo "Error: --count must be a non-negative integer." >&2
        exit 1
    fi
    COUNT=$((10#$COUNT))
    if ((COUNT > 1000000)); then
        echo "Error: --count must not exceed 1000000." >&2
        exit 1
    fi

    # 4. Check if WARN threshold is strictly less than CRIT threshold for each metric
    if ! is_less_than "$CPU_WARN" "$CPU_CRIT"; then
        echo "Error: CPU warning ($CPU_WARN) must be less than critical ($CPU_CRIT)." >&2
        exit 1
    fi

    if ! is_less_than "$MEM_WARN" "$MEM_CRIT"; then
        echo "Error: Memory warning ($MEM_WARN) must be less than critical ($MEM_CRIT)." >&2
        exit 1
    fi

    if ! is_less_than "$SWAP_WARN" "$SWAP_CRIT"; then
        echo "Error: Swap warning ($SWAP_WARN) must be less than critical ($SWAP_CRIT)." >&2
        exit 1
    fi

    if ! is_less_than "$LOAD_WARN" "$LOAD_CRIT"; then
        echo "Error: Load warning ($LOAD_WARN) must be less than critical ($LOAD_CRIT)." >&2
        exit 1
    fi

    # 5. Check whether thresholds do not exceed 100
    for val in "$CPU_WARN" "$CPU_CRIT" "$MEM_WARN" "$MEM_CRIT" "$SWAP_WARN" "$SWAP_CRIT"; do
        if is_less_than "100" "$val"; then
        echo "Error: Percentage threshold '$val' cannot be greater than 100." >&2
        exit 1
        fi
    done
}


# ==============================================================================
# CLASSIFICATION & ALERTS
# ==============================================================================

classify_metric() {
    local val="$1"
    local warn="$2"
    local crit="$3"

    awk -v v="$val" -v w="$warn" -v c="$crit" 'BEGIN {
        if (v >= c) print "CRIT"
        else if (v >= w) print "WARN"
        else print "OK"
    }'
}

classify_all_metrics() {
    local label busy user_pct system_pct iowait idle steal i
    # Adapt Alyssa's report into the per-core array expected by Mita's code.
    CPU_CORE_PCT=()
    while read -r label busy user_pct system_pct iowait idle steal; do
        if [[ "$label" != cpu ]]; then
        i=${label#cpu}
        CPU_CORE_PCT[i]="$busy"
        fi
    done <<< "$CPU_REPORT"
    CPU_STAT=$(classify_metric "$CPU_TOTAL_PCT" "$CPU_WARN" "$CPU_CRIT")
    MEM_STAT=$(classify_metric "$MEM_USED_PCT" "$MEM_WARN" "$MEM_CRIT")
    SWAP_STAT=$(classify_metric "$SWAP_USED_PCT" "$SWAP_WARN" "$SWAP_CRIT")
    if ((SWAP_TOTAL_KIB == 0)); then SWAP_STAT=OK; fi
    # Compare raw load with equivalent raw limits, avoiding rounded-load decisions.
    LOAD_DISPLAY_WARN=$(awk -v n="$LOAD_WARN" -v c="$CORE_COUNT" 'BEGIN { print n*c }')
    LOAD_DISPLAY_CRIT=$(awk -v n="$LOAD_CRIT" -v c="$CORE_COUNT" 'BEGIN { print n*c }')
    LOAD_STAT=$(classify_metric "$LOAD_1" "$LOAD_DISPLAY_WARN" "$LOAD_DISPLAY_CRIT")

    CPU_CORES_STAT=()
    for i in "${!CPU_CORE_PCT[@]}"; do
        CPU_CORES_STAT[i]=$(classify_metric "${CPU_CORE_PCT[$i]}" "$CPU_WARN" "$CPU_CRIT")
    done
}

track_alert() {
    local name="$1"        # Metric name
    local current="$2"     # Current status ("OK", "WARN", "CRIT")
    local prev_var="$3"    # Variable name storing previous status
    local val="$4"         # Current numeric value string
    local threshold="$5"   # Threshold string
    local time_str="$6"    # Time string

    # Indirect variable expansion to retrieve the previous state string
    local prev="${!prev_var}"
    if [[ "$val" == *% ]]; then val="$(one_decimal "${val%\%}")%"; fi

    # 1. State hasn't changed -> suppress duplicate output
    if [[ "$current" == "$prev" ]]; then
        return
    fi

    # 2. Transitioning into a bad state (OK -> WARN, OK -> CRIT, or WARN -> CRIT)
    if [[ "$current" != "OK" ]]; then
        echo "ALERT  $name entered $current ($val >= $threshold) at $time_str"
    
    # 3. Transitioning back to normal (WARN -> OK or CRIT -> OK)
    elif [[ "$current" == "OK" && "$prev" != "OK" ]]; then
        echo "RECOVER $name returned to OK ($val) at $time_str"
    fi

    # Update the dynamic global tracking variable to match current state
    printf -v "$prev_var" "%s" "$current"
}

track_all_alerts() {
    local time_now
    local i core_thresh
    time_now=${TIMESTAMP#*T}
    time_now=${time_now:0:8}

    local cpu_thresh="$CPU_WARN"
    [[ "$CPU_STAT" == "CRIT" ]] && cpu_thresh="$CPU_CRIT"
    track_alert "CPU total" "$CPU_STAT" "PREV_CPU_STAT" "${CPU_TOTAL_PCT}%" "${cpu_thresh}%" "$time_now"

    local mem_thresh="$MEM_WARN"
    [[ "$MEM_STAT" == "CRIT" ]] && mem_thresh="$MEM_CRIT"
    track_alert "Memory" "$MEM_STAT" "PREV_MEM_STAT" "${MEM_USED_PCT}%" "${mem_thresh}%" "$time_now"

    local swap_thresh="$SWAP_WARN"
    [[ "$SWAP_STAT" == "CRIT" ]] && swap_thresh="$SWAP_CRIT"
    track_alert "Swap" "$SWAP_STAT" "PREV_SWAP_STAT" "${SWAP_USED_PCT}%" "${swap_thresh}%" "$time_now"

    local load_thresh="$LOAD_DISPLAY_WARN"
    [[ "$LOAD_STAT" == "CRIT" ]] && load_thresh="$LOAD_DISPLAY_CRIT"
    track_alert "Load (1m)" "$LOAD_STAT" "PREV_LOAD_STAT" "$LOAD_1" "$load_thresh" "$time_now"
    for i in "${!CPU_CORE_PCT[@]}"; do
        PREV_CURRENT_CORE_STAT=${PREV_CORE_STAT[$i]:-OK}
        core_thresh="$CPU_WARN"
        if [[ "${CPU_CORES_STAT[$i]}" == CRIT ]]; then core_thresh="$CPU_CRIT"; fi
        track_alert "CPU core$i" "${CPU_CORES_STAT[$i]}" PREV_CURRENT_CORE_STAT \
        "${CPU_CORE_PCT[$i]}%" "$core_thresh%" "$time_now"
        PREV_CORE_STAT[i]="$PREV_CURRENT_CORE_STAT"
    done
}


# ==============================================================================
# PRINTING & CSV LOGGING
# ==============================================================================

print_sample() {
    local sample_num="$1"
    local timestamp="$TIMESTAMP"
    local i target_count="$COUNT"
    if ((COUNT == 0)); then target_count=unlimited; fi

    # Header
    echo "=== System Resource Monitor -- sample ${sample_num}/${target_count} -- ${timestamp} ==="
    echo ""
    format_row "METRIC" "VALUE" "THRESHOLD" "STATUS" "DETAIL"
    echo "--------------------------------------------------------------------------------"

    # CPU Total row
    local cpu_detail
    cpu_detail="user $(one_decimal "$CPU_USER_PCT")  sys $(one_decimal "$CPU_SYSTEM_PCT")  iowait $(one_decimal "$CPU_IOWAIT_PCT")"
    format_row \
        "CPU total" "$(one_decimal "$CPU_TOTAL_PCT") %" "warn ${CPU_WARN}/crit ${CPU_CRIT}" "$CPU_STAT" "$cpu_detail"

    # Per-core CPU rows
    for i in "${!CPU_CORE_PCT[@]}"; do
        local core_detail=""
        if awk -v busy="${CPU_CORE_PCT[$i]}" 'BEGIN { exit !(busy >= 95) }'; then
        core_detail="saturated"
        fi
        format_row \
        "CPU core${i}" "$(one_decimal "${CPU_CORE_PCT[$i]}") %" "warn ${CPU_WARN}/crit ${CPU_CRIT}" "${CPU_CORES_STAT[$i]}" "$core_detail"
    done

    # Memory row
    local mem_used_gib
    mem_used_gib=$(awk -v kib="$MEM_USED_KIB" 'BEGIN { printf "%.1f", kib / 1048576 }')
    local mem_total_gib
    mem_total_gib=$(awk -v kib="$MEM_TOTAL_KIB" 'BEGIN { printf "%.1f", kib / 1048576 }')
    local mem_detail="${mem_used_gib} GiB of ${mem_total_gib} GiB used"

    format_row \
        "Memory" "$(one_decimal "$MEM_USED_PCT") %" "warn ${MEM_WARN}/crit ${MEM_CRIT}" "$MEM_STAT" "$mem_detail"

    # Swap row
    local swap_detail="no swap in use"
    if awk -v s="$SWAP_USED_PCT" 'BEGIN { exit !(s > 0) }'; then
        swap_detail="${SWAP_USED_KIB} KiB of ${SWAP_TOTAL_KIB} KiB used"
    fi
    if ((SWAP_TOTAL_KIB == 0)); then swap_detail="no swap configured"; fi
    format_row \
        "Swap" "$(one_decimal "$SWAP_USED_PCT") %" "warn ${SWAP_WARN}/crit ${SWAP_CRIT}" "$SWAP_STAT" "$swap_detail"

    # Load row
    local load_detail="${LOAD_1} over ${CORE_COUNT} cores = ${LOAD_NORMALISED} per core"
    format_row \
        "Load (1m)" "${LOAD_1}" "warn $(format_load_limit "$LOAD_DISPLAY_WARN")/crit $(format_load_limit "$LOAD_DISPLAY_CRIT")" "$LOAD_STAT" "$load_detail"

    # Processes row
    local proc_detail="${PROCS_RUNNING} running, ${PROCS_TOTAL} total"
    format_row \
        "Processes" "${PROCS_TOTAL}" "-" "OK" "$proc_detail"

    echo ""
}


# Write the CSV header
init_csv_file() {
    local header existing
    header='timestamp,cpu_total,cpu_user,cpu_system,cpu_iowait,mem_used_pct,mem_used_kib,swap_used_pct,load1,load5,load15,procs_running,procs_total,status'
    LOCK_DIR="$CSV_FILE.lock"
    if ! mkdir -- "$LOCK_DIR"; then
        echo "Cannot lock CSV; check the path or another monitor using this file." >&2
        return 1
    fi
    LOCK_HELD=1
    if [[ ! -s "$CSV_FILE" ]]; then
        printf '%s\n' "$header" >> "$CSV_FILE"
    else
        IFS= read -r existing < "$CSV_FILE"
        if [[ "$existing" != "$header" || -n "$(tail -c 1 -- "$CSV_FILE")" ]]; then
        echo "Existing CSV has a different header or incomplete last line. Use --csv with a new path." >&2
        return 1
        fi
    fi
}

# Append one row per sample pass
write_csv_row() {
    local timestamp="$TIMESTAMP"
    local i

    # Overall row status is the worst status across primary metrics
    local overall_status="OK"
    if [[ "$CPU_STAT" == "CRIT" || "$MEM_STAT" == "CRIT" || "$SWAP_STAT" == "CRIT" || "$LOAD_STAT" == "CRIT" ]]; then
        overall_status="CRIT"
    elif [[ "$CPU_STAT" == "WARN" || "$MEM_STAT" == "WARN" || "$SWAP_STAT" == "WARN" || "$LOAD_STAT" == "WARN" ]]; then
        overall_status="WARN"
    fi
    for i in "${!CPU_CORES_STAT[@]}"; do
        if [[ "${CPU_CORES_STAT[$i]}" == CRIT ]]; then
        overall_status=CRIT
        elif [[ "${CPU_CORES_STAT[$i]}" == WARN && "$overall_status" == OK ]]; then
        overall_status=WARN
        fi
    done

    local row
    printf -v row '%s,%.2f,%.2f,%.2f,%.2f,%.2f,%s,%.2f,%.2f,%.2f,%.2f,%s,%s,%s' \
        "$timestamp" "$CPU_TOTAL_PCT" "$CPU_USER_PCT" "$CPU_SYSTEM_PCT" "$CPU_IOWAIT_PCT" \
        "$MEM_USED_PCT" "$MEM_USED_KIB" "$SWAP_USED_PCT" "$LOAD_1" "$LOAD_5" "$LOAD_15" \
        "$PROCS_RUNNING" "$PROCS_TOTAL" "$overall_status"
    printf '%s\n' "$row" >> "$CSV_FILE"
}

print_cpu_report() {
    local label busy user_pct system_pct iowait idle steal
    printf '\n%-10s %8s %8s %8s %8s %8s %8s\n' \
        'CPU' 'Busy%' 'User%' 'System%' 'IOwait%' 'Idle%' 'Steal%'
    while read -r label busy user_pct system_pct iowait idle steal; do
        printf '%-10s %8s %8s %8s %8s %8s %8s\n' \
            "$label" "$busy" "$user_pct" "$system_pct" "$iowait" "$idle" "$steal"
    done <<< "$CPU_REPORT"
}

print_memory_load_report() {
    printf '\nMemory: %s%% | used %s KiB | available %s KiB | total %s KiB\n' \
        "$MEM_USED_PCT" "$MEM_USED_KIB" "$MEM_AVAILABLE_KIB" "$MEM_TOTAL_KIB"
    if ((SWAP_TOTAL_KIB == 0)); then
        printf 'Swap: no swap configured (reported usage 0.00%%)\n'
    else
        printf 'Swap: %s%% | used %s KiB | free %s KiB | total %s KiB\n' \
            "$SWAP_USED_PCT" "$SWAP_USED_KIB" "$SWAP_FREE_KIB" "$SWAP_TOTAL_KIB"
    fi
    printf 'Load: 1m=%s 5m=%s 15m=%s | cores=%s | 1m per core=%s\n' \
        "$LOAD_1" "$LOAD_5" "$LOAD_15" "$CORE_COUNT" "$LOAD_NORMALISED"
    printf 'Processes (assignment labels): %s running / %s total\n' \
        "$PROCS_RUNNING" "$PROCS_TOTAL"
}

# ==============================================================================
# SUMMARY & CLEANUP
# ==============================================================================

get_max() {
    awk -v cur="$1" -v peak="$2" 'BEGIN { print (cur > peak) ? cur : peak }'
}

update_summary_stats() {
    local i
    SAMPLES_TAKEN=$((SAMPLES_TAKEN + 1))
    SAMPLED_SECONDS=$(add_seconds "$SAMPLED_SECONDS" "$SAMPLE_SECONDS")

    PEAK_CPU=$(get_max "$CPU_TOTAL_PCT" "$PEAK_CPU")
    PEAK_MEM=$(get_max "$MEM_USED_PCT" "$PEAK_MEM")
    PEAK_SWAP=$(get_max "$SWAP_USED_PCT" "$PEAK_SWAP")
    PEAK_LOAD=$(get_max "$LOAD_NORMALISED" "$PEAK_LOAD")

    case "$CPU_STAT" in
        WARN) CPU_WARN_SEC=$(add_seconds "$CPU_WARN_SEC" "$SAMPLE_SECONDS") ;;
        CRIT) CPU_CRIT_SEC=$(add_seconds "$CPU_CRIT_SEC" "$SAMPLE_SECONDS") ;;
    esac
    case "$MEM_STAT" in
        WARN) MEM_WARN_SEC=$(add_seconds "$MEM_WARN_SEC" "$SAMPLE_SECONDS") ;;
        CRIT) MEM_CRIT_SEC=$(add_seconds "$MEM_CRIT_SEC" "$SAMPLE_SECONDS") ;;
    esac
    case "$SWAP_STAT" in
        WARN) SWAP_WARN_SEC=$(add_seconds "$SWAP_WARN_SEC" "$SAMPLE_SECONDS") ;;
        CRIT) SWAP_CRIT_SEC=$(add_seconds "$SWAP_CRIT_SEC" "$SAMPLE_SECONDS") ;;
    esac
    case "$LOAD_STAT" in
        WARN) LOAD_WARN_SEC=$(add_seconds "$LOAD_WARN_SEC" "$SAMPLE_SECONDS") ;;
        CRIT) LOAD_CRIT_SEC=$(add_seconds "$LOAD_CRIT_SEC" "$SAMPLE_SECONDS") ;;
    esac
    for i in "${!CPU_CORE_PCT[@]}"; do
        PEAK_CORE[i]=$(get_max "${CPU_CORE_PCT[$i]}" "${PEAK_CORE[$i]:-0}")
        CORE_WARN_SEC[i]=${CORE_WARN_SEC[$i]:-0}
        CORE_CRIT_SEC[i]=${CORE_CRIT_SEC[$i]:-0}
        case "${CPU_CORES_STAT[$i]}" in
            WARN) CORE_WARN_SEC[i]=$(add_seconds "${CORE_WARN_SEC[$i]}" "$SAMPLE_SECONDS") ;;
            CRIT) CORE_CRIT_SEC[i]=$(add_seconds "${CORE_CRIT_SEC[$i]}" "$SAMPLE_SECONDS") ;;
        esac
    done
}

print_summary() {
    echo ""
    echo "=================== Execution Summary ==================="
    echo "Total Samples Taken : $SAMPLES_TAKEN"
    echo "Total Runtime       : $((SAMPLES_TAKEN * INTERVAL)) seconds"
    echo "---------------------------------------------------------"
    printf "%-10s  %-12s  %-14s  %-12s\n" "METRIC" "PEAK VALUE" "TIME IN WARN" "TIME IN CRIT"
    echo "---------------------------------------------------------"
    printf "%-10s  %-12s  %-14s  %-12s\n" "CPU TOTAL"    "${PEAK_CPU}%"  "${CPU_WARN_SEC}s"  "${CPU_CRIT_SEC}s"
    
    local i
    for i in "${!PEAK_CORE[@]}"; do
        printf "%-10s  %-12s  %-14s  %-12s\n" \
        "CPU core$i" \
        "${PEAK_CORE[$i]}%" \
        "${CORE_WARN_SEC[$i]}s" \
        "${CORE_CRIT_SEC[$i]}s"
    done
    printf "%-10s  %-12s  %-14s  %-12s\n" "Memory" "${PEAK_MEM}%"  "${MEM_WARN_SEC}s"  "${MEM_CRIT_SEC}s"
    printf "%-10s  %-12s  %-14s  %-12s\n" "Swap"   "${PEAK_SWAP}%" "${SWAP_WARN_SEC}s" "${SWAP_CRIT_SEC}s"
    printf "%-10s  %-12s  %-14s  %-12s\n" "Load"   "${PEAK_LOAD}"  "${LOAD_WARN_SEC}s" "${LOAD_CRIT_SEC}s"
    echo "========================================================="
}

cleanup() {
    local exit_status="$1"
    # Prevent duplicate execution if trap triggers on both INT and EXIT
    if [[ "$CLEANUP_DONE" -eq 1 ]]; then
        return
    fi
    CLEANUP_DONE=1

    trap - EXIT
    if [[ -n "$SLEEP_PID" ]]; then
        kill "$SLEEP_PID" 2>/dev/null || true
        wait "$SLEEP_PID" 2>/dev/null || true
    fi
    if ((LOCK_HELD == 1)); then rmdir -- "$LOCK_DIR" || true; fi

    # Print summary before exit
    print_summary
    # Preserve errors rather than reporting failed runs as successful.
    exit "$exit_status"
}

format_row() {
    printf '%-20s %-12s %-24s %-8s %s\n' "$1" "$2" "$3" "$4" "$5"
}

one_decimal() {
    awk -v n="$1" 'BEGIN { printf "%.1f", n }'
}

format_load_limit() {
    # Keep .0 for whole thresholds, but do not hide fractional custom limits.
    awk -v n="$1" 'BEGIN { if (n == int(n)) printf "%.1f", n; else printf "%.10g", n }'
}

add_seconds() {
    awk -v a="$1" -v b="$2" 'BEGIN { printf "%.2f", a+b }'
}

print_extra_details() {
    printf 'CPU breakdown (steal is the extra metric)'
    print_cpu_report
    print_memory_load_report
    printf '\n'
}

check_environment() {
    if [[ ! -r /proc/stat || ! -r /proc/meminfo || ! -r /proc/loadavg || ! -r /proc/uptime ]]; then
        echo 'Run this tool inside Ubuntu/Linux, not the Mac terminal.' >&2
        return 1
    fi
}

read_elapsed_time() {
    awk '{ print $1 }' /proc/uptime
}

request_stop() {
    STOP_REQUESTED=1
    if [[ -n "$SLEEP_PID" ]]; then kill "$SLEEP_PID" 2>/dev/null || true; fi
}
