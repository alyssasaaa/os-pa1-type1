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
    MEM_USED_KIB=$((mem_total - mem_available))
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

collect_memory
collect_load

printf 'Cores: %s\n' "$CORE_COUNT"
printf 'Memory: %s%% (%s KiB used)\n' "$MEM_USED_PCT" "$MEM_USED_KIB"
printf 'Swap: %s%%\n' "$SWAP_USED_PCT"
printf 'Load: %s %s %s\n' "$LOAD_1" "$LOAD_5" "$LOAD_15"
printf 'Normalised load: %s\n' "$LOAD_NORMALISED"
printf 'Processes: %s running / %s total\n' \
    "$PROCS_RUNNING" "$PROCS_TOTAL"