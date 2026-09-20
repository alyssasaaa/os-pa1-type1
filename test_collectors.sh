#!/usr/bin/env bash
set -euo pipefail

main() {
    local script_dir previous current sample
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    # shellcheck source=lib/collectors.sh
    source "$script_dir/lib/collectors.sh"
    if [[ ! -r /proc/stat || ! -r /proc/meminfo ]]; then
        printf 'Run this test inside Ubuntu, where /proc is available.\n' >&2
        return 1
    fi
    trap 'printf "\nCollector test interrupted.\n"; exit 130' INT
    previous=$(read_cpu_snapshot)
    for sample in 1 2 3; do
        sleep 1
        current=$(read_cpu_snapshot)
        calculate_cpu_usage "$previous" "$current"
        collect_memory
        collect_load
        printf '\n=== SAMPLE %s/3 ===\n' "$sample"
        print_cpu_report
        print_memory_load_report
        previous="$current"
    done
}

main "$@"