## SYSTEM RESOURCE MONITOR & ALERTING

## Member contributions

| Member | Student ID | Actual contribution |
|---|---|---|
| Alyssa Rahma Adjani | 2506558466 | Developed and tested the resource-collection functions in lib/collectors.sh, covering aggregate and per-core CPU utilisation, memory and swap usage, load averages, and process counts. Collaborated on resmon.sh and prepared explanation.md. |
| Paramita Santoso | 2506554171 | Developed the monitoring functions in lib/monitoring.sh, including threshold classification, state-change alerts, report formatting, CSV logging, and execution summaries. Collaborated on resmon.sh and prepared the presentation slides in Google Slides. |

### What is this project about?

This project is a Bash command-line monitor for Linux Ubuntu Server 24.04 LTS that reads the system statistics, calculates resource usage, and reports conditions that may require attention.

The program obtains its data directly from the /proc virtual filesystem, which exposes information maintained by the Linux Kernel. We use:
    - /proc/stat for CPU counters.
    - /proc/meminfo for memory and swap statistics.
    - /proc/loadavg for load averages and running/total task counts.

The program is divided into three main files. lib/collectors.sh collects and calculates the measurements, lib/monitoring.sh classifies and reports the results, and resmon.sh controls the program flow. 

### What does it do, and why does it matter?

1. Measures CPU utilisation for the whole system and each logical CPU, including user, system, iowait, and idle percentages.
2. Reports memory and swap usage, 1-, 5-, and 15-minute load averages, running/task counts, and normalised 1-minute load. 
3. Steal-time percentage is included as an additional metric for virtual machines.

The reporting component classifies selected metrics as OK, WARN, or CRIT, displays alerts when their states change, and saves timestamped results to a CSV file.

These measurements help explain and distinguish causes why a system may be slow. For example, one logical CPU may be fully occupied while the overall CPU utilisation is only moderate. Low free memory also does not always mean that the system is running out of usable memory. 

### How to run it?

Project structure:
os-pa1-type1/
├── resmon.sh
├── explanation.md
└── lib/
    ├── collectors.sh
    └── monitoring.sh

1. Open terminal inside Ubuntu
2. Set project directory inside Ubuntu. In this case it's
```bash
    cd ~/os-pa1-type1
```
3. Run these commands:
```bash
    bash -n lib/collectors.sh
    bash -n lib/monitoring.sh
    bash -n resmon.sh
    chmod +x resmon.sh
    ./resmon.sh --help
    ./resmon.sh --interval 1 --count 3
    ./resmon.sh --interval 1 --count 3 --cpu-crit 85
```
Defaults are interval 1, count 3, CPU thresholds 70/90, memory 75/90, swap 20/50, and load per core 1/2. Percentage thresholds range from 0 to 100, with warning no greater than critical. Invalid arguments produce an error and a nonzero exit status.

Results are displayed in the terminal and appended to resource_report.csv (with timestamp UTC)

Try run with timestamp Indonesia (UTC+7):
```bash
    TZ=Asia/Jakarta ./resmon.sh --interval 1 --count 0 --cpu-warn 20 --cpu-crit 40
```
### No. 1: Why IOWait is excluded from the numerator but reported separately?

IOWait is a metric that measures the percentage of time a computer's CPU is idle because it is waiting for an I/O operation. Since it accounts for idle time and is not an actual CPU activity, including it in the CPU usage numerator would overstate the busy usage. 

However, IOWait is a critical diagnostic health signal. Meaning, reporting it separately helps identify possible I/O-related delays and distinguish between two types of idle states: pure idle (no wordk to do) and IO/Wait (system has tasks to do, but blocked by slow storage). 

### No. 2: Why MemAvailable instead of MemFree? Explain the difference

MemFree: the amount of physical RAM that is strictly unused and sitting empty.

MemAvailable: the kernel's estimate of how much available memory can be supplied to new applications without trigger swapping. This estimate includes unused memory and portions of reclaimable memory. 

The collector reads /proc/meminfo and calculates:
mem_used = MemTotal - MemAvailale
mem_used_pct = mem_used / MemTotal * 100

We use MemAvailable because Linux uses some RAM to cache data and make later access faster. 

### No. 6: Explain the alert state machine and de-duplication

For each monitored metric, the program remembers its previous state and compares it with the current state.

Classification rules:
value >= critical --> CRIT
otherwise, value >= warning --> WARN
otherwise --> OK

The program then decides what to print message as an output, is it an ALERT, or RECOVER, or neither: 
| Previous state | New state | Action | New Stored State |
|---|---|---|---|
| OK | WARN | Output ALERT (Warning threshold reached) | WARN
| OK | CRIT | Output ALERT (Critical threshold reached) | CRIT
| WARN | CRIT | Output ALERT (Escalated to Critical) | CRIT
| CRIT | WARN | Output ALERT (De-escalated to Warning) | WARN
| WARN or CRIT | OK | Output RECOVER (Returned to Norma) | OK
| Any state | Same state | None | Unchanged

### Additional metric: CPU steal time

CPU steal time is the percentage of time a virtual CPU waits for a real CPU while the hypervisor is servicing another virtual processor.

Our collector calculates:
steal_pct = (steal_current − steal_previous)
            / (total_current − total_previous) × 100

We display it for the whole system and each logical CPU in the CPU breakdown. 

This matters because a VM may respons slowly even when its own programs do not explain the delay. A non-zero steal percentage means that some CPU time was unavailable to our VM during the sampling interval. Our hypervisor neighbours may be competing for physical CPU time. A small value does not necessarily indicate a problem, while consistently high values can suggest competition for CPU resources.

Following the assignment’s formula, steal is included in the busy (time other than idle) calculation, but it is not time spent executing our own programs. We therefore also display it separately. It is informational in our monitor and does not have its own warning or critical threshold.

Steal time (/proc/stat field 8) in our awk code is $9 because $1 contains the CPU label. 