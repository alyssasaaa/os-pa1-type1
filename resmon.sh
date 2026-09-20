#!/usr/bin/env bash
set -euo pipefail

main() {
    local script_dir
    local previous
    local current
    local previous_time
    local current_time

    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    # shellcheck source=lib/collectors.sh
    source "$script_dir/lib/collectors.sh"
    # shellcheck source=lib/monitoring.sh
    source "$script_dir/lib/monitoring.sh"

    export LC_ALL=C
    initialise_settings
    parse_arguments "$@"
    validate_arguments
    check_environment

    trap 'request_stop' INT TERM HUP
    trap 'cleanup "$?"' EXIT
    init_csv_file
    previous=$(read_cpu_snapshot)
    previous_time=$(read_elapsed_time)

    while ((COUNT == 0 || SAMPLES_TAKEN < COUNT)); do
        if ((STOP_REQUESTED == 1)); then
            break
        fi
        sleep "$INTERVAL" &
        SLEEP_PID=$!
        if wait "$SLEEP_PID"; then
            SLEEP_PID=""
        else
            if ((STOP_REQUESTED == 0)); then
                printf 'Sampling sleep failed.\n' >&2
                return 1
            fi
        fi
        if ((STOP_REQUESTED == 1)); then
            break
        fi

        current=$(read_cpu_snapshot)
        current_time=$(read_elapsed_time)
        SAMPLE_SECONDS=$(awk -v before="$previous_time" -v after="$current_time" \
            'BEGIN { printf "%.2f", after - before }')
        calculate_cpu_usage "$previous" "$current"
        collect_memory
        collect_load
        TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S%:z')

        # Signals only set a flag. Finish this sample, including its CSV row.
        classify_all_metrics
        write_csv_row
        update_summary_stats
        print_sample "$SAMPLES_TAKEN"
        track_all_alerts
        print_extra_details
        previous="$current"
        previous_time="$current_time"
    done
}

main "$@"
