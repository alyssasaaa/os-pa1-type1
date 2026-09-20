#!/usr/bin/env bash

count_cpu_cores() {
    grep -Ec '^cpu[0-9]+ ' /proc/stat
}

collect_memory() {
    local mem_total
    local mem_available
    local swap_total
    local swap_free

    mem_total=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
    mem_available=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)
    swap_total=$(awk '/^SwapTotal:/ { print $2 }' /proc/meminfo)
    swap_free=$(awk '/^SwapFree:/ { print $2 }' /proc/meminfo)

    MEM_TOTAL_KIB="$mem_total"
    MEM_AVAILABLE_KIB="$mem_available"
    MEM_USED_KIB=$((mem_total - mem_available))

    SWAP_TOTAL_KIB="$swap_total"
    SWAP_FREE_KIB="$swap_free"
    SWAP_USED_KIB=$((swap_total - swap_free))

    MEM_USED_PCT=$(awk \
        -v used="$MEM_USED_KIB" \
        -v total="$MEM_TOTAL_KIB" \
        'BEGIN { printf "%.2f", used / total * 100 }')

    if ((swap_total == 0)); then
        SWAP_USED_PCT="0.00"
    else
        SWAP_USED_PCT=$(awk \
            -v used="$SWAP_USED_KIB" \
            -v total="$swap_total" \
            'BEGIN { printf "%.2f", used / total * 100 }')
    fi
}

collect_load() {
    local process_counts

    read -r LOAD_1 LOAD_5 LOAD_15 process_counts _ < /proc/loadavg

    PROCS_RUNNING=${process_counts%/*}
    PROCS_TOTAL=${process_counts#*/}
    CORE_COUNT=$(count_cpu_cores)

    LOAD_NORMALISED=$(awk \
        -v load_value="$LOAD_1" \
        -v cores="$CORE_COUNT" \
        'BEGIN { printf "%.2f", load_value / cores }')
}

read_cpu_snapshot() {
    awk '/^cpu([0-9]+)?[[:space:]]/ { print }' /proc/stat
}

# FORMULA:
# busy  = user + nice + system + irq + softirq + steal
# total = busy + idle + iowait
# util  = (busy₁ − busy₀) / (total₁ − total₀) × 100 

# inside /proc/stat
# $1 --> label, $2 --> user, $3 --> nice
# $4 --> system, $5 --> idle, $6 --> iowait
# $7 --> irq, $8 --> softirq, $9 --> steal

# UPDATED FORMULA BASED ON INDEX of /proc/stat:
# busy = delta[2] + delta[3] + delta[4] + delta[7] + delta[8] + delta[9]

calculate_cpu_usage() {
    local previous 
    local current 
    local label

    previous="$1"
    current="$2"
    CPU_REPORT=$(printf '%s\nNEXT_SNAPSHOT\n%s\n' "$previous" "$current" |
        awk '
            /^NEXT_SNAPSHOT$/ { second = 1; next }
            /^cpu([0-9]+)?[[:space:]]/ {
                label = $1;
                if (!second) {
                    seen[label] = 1;
                    for (i = 2; i <= 9; i++) old[label, i] = $i;
                    next;
                }
                if (!(label in seen)) next;
                for (i = 2; i <= 9; i++) {
                    delta[i] = $i - old[label, i];
                }
                busy = delta[2] + delta[3] + delta[4] + delta[7] + delta[8] + delta[9];
                total = busy + delta[5]+ delta[6];

                if (total <= 0) {
                    print "CPU interval has no positive counter delta" > "/dev/stderr";
                    exit 1;
                }
                printf "%s %.2f %.2f %.2f %.2f %.2f %.2f\n", label,
                    busy / total * 100, delta[2] / total * 100,
                    delta[4] / total * 100, delta[6] / total * 100,
                    delta[5] / total * 100, delta[9] / total * 100;
            }
        ') || return 1
    [[ -n "$CPU_REPORT" ]] || return 1
    read -r label CPU_TOTAL_PCT CPU_USER_PCT CPU_SYSTEM_PCT CPU_IOWAIT_PCT CPU_IDLE_PCT CPU_STEAL_PCT <<< "$CPU_REPORT"
    [[ "$label" == cpu ]]
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
