#!/bin/zsh

# Independent hard-stop process for mac-filter-smoke-test.zsh. It deliberately
# has no dependency on the app process, Network Extension callbacks, or network
# connectivity. The absolute deadline prevents launch latency from extending
# the enabled window.

set -u

app_path="$1"
deadline_epoch="$2"
test_id="$3"
armed_file="$4"
completed_file="$5"
report_directory="${armed_file:h}"
unsafe_latch_file="${6:-$report_directory/UNSAFE-REBOOT-REQUIRED.tsv}"
unsafe_latch_lock_file="$unsafe_latch_file.lock"
enforcement_safety_reporter="$app_path/Contents/MacOS/Holdfast"
boot_session_id="${7:-}"
control_https_probe_address="${8:-}"
recovery_deadline_epoch="${9:-$(( deadline_epoch + 30 ))}"
recovery_log="$report_directory/watchdog-recovery.tsv"
unsafe_condition_observed=0
unsafe_latch_lock_fd=""
enforcement_safety_snapshot_sequence=0
enforcement_safety_blocking_disabled=""
if [[ -z "$boot_session_id" ]]; then
    boot_session_id="$(/usr/sbin/sysctl -n kern.bootsessionuuid 2>/dev/null || true)"
fi
if [[ -z "$boot_session_id" ]]; then
    boot_session_id="$(/usr/sbin/sysctl -n kern.boottime 2>/dev/null || print -r -- unknown)"
fi

request_disable() {
    local reason="$1" mark_startup_unsafe="${2:-0}" result
    pkill -x Holdfast >/dev/null 2>&1 || true
    if [[ "$mark_startup_unsafe" == "1" ]]; then
        open -na "$app_path" --args \
            --disable-web-filter-now --mark-filter-startup-unsafe >/dev/null 2>&1
    else
        open -na "$app_path" --args --disable-web-filter-now >/dev/null 2>&1
    fi
    result=$?
    print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) disable_requested id=$test_id reason=$reason mark_startup_unsafe=$mark_startup_unsafe result=$result"
}

acquire_unsafe_latch_lock() {
    local timeout_seconds="${1:-2}"
    [[ -z "$unsafe_latch_lock_fd" ]] || return 1
    if ! exec {unsafe_latch_lock_fd}> "$unsafe_latch_lock_file"; then
        unsafe_latch_lock_fd=""
        return 1
    fi
    if /usr/bin/lockf -s -t "$timeout_seconds" "$unsafe_latch_lock_fd"; then
        return 0
    fi
    exec {unsafe_latch_lock_fd}>&-
    unsafe_latch_lock_fd=""
    return 1
}

release_unsafe_latch_lock() {
    if [[ -n "$unsafe_latch_lock_fd" ]]; then
        exec {unsafe_latch_lock_fd}>&-
        unsafe_latch_lock_fd=""
    fi
}

load_enforcement_safety_snapshot() {
    local output_file temporary_file stderr_file reporter_result
    enforcement_safety_snapshot_sequence=$(( enforcement_safety_snapshot_sequence + 1 ))
    output_file="$report_directory/watchdog-enforcement-safety-$enforcement_safety_snapshot_sequence.json"
    temporary_file="$output_file.tmp"
    stderr_file="$output_file.stderr"
    /usr/bin/perl -e 'alarm shift; exec @ARGV; exit 127' \
        3 "$enforcement_safety_reporter" --report-enforcement-safety-state \
        > "$temporary_file" 2> "$stderr_file"
    reporter_result=$?
    if (( reporter_result != 0 )); then
        /bin/mv -f "$temporary_file" "$output_file.failed" 2>/dev/null || true
        print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) enforcement_safety_report_failed id=$test_id exit=$reporter_result timeout_seconds=3"
        return 1
    fi
    if ! /usr/bin/jq -e \
        'type == "object" and (.blockingDisabled | type == "boolean")' \
        "$temporary_file" >/dev/null 2>&1; then
        /bin/mv -f "$temporary_file" "$output_file.invalid" 2>/dev/null || true
        print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) enforcement_safety_report_failed id=$test_id failure=invalid-json-or-schema"
        return 1
    fi
    /bin/mv -f "$temporary_file" "$output_file"
    enforcement_safety_blocking_disabled="$(/usr/bin/jq -r '.blockingDisabled' "$output_file" 2>/dev/null || true)"
    [[ "$enforcement_safety_blocking_disabled" == "true" \
        || "$enforcement_safety_blocking_disabled" == "false" ]]
}

blocking_disable_is_persisted() {
    load_enforcement_safety_snapshot \
        && [[ "$enforcement_safety_blocking_disabled" == "true" ]]
}

control_connectivity_is_healthy() {
    local dns_output dns_result https_output https_result dns_ok=0 https_ok=0
    dns_output="$(/usr/bin/dig +time=1 +tries=1 +short example.com A 2>&1)"
    dns_result=$?
    if (( dns_result == 0 )) && print -r -- "$dns_output" | /usr/bin/grep -Eq \
        '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        dns_ok=1
    fi
    if [[ -n "$control_https_probe_address" ]]; then
        https_output="$(curl --connect-timeout 1 --max-time 2 -sS -o /dev/null \
            --resolve "example.com:443:$control_https_probe_address" \
            -w 'http=%{http_code},total=%{time_total}' https://example.com 2>&1)"
        https_result=$?
        if (( https_result == 0 )) && [[ "$https_output" == *"http=200"* ]]; then
            https_ok=1
        fi
    else
        https_output="control address unavailable"
        https_result=69
    fi
    dns_output="${dns_output//$'\n'/,}"
    https_output="${https_output//$'\n'/ }"
    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$dns_ok" "$https_ok" \
        "$dns_result" "$https_result" "$dns_output" "$https_output" >> "$recovery_log"
    (( dns_ok == 1 && https_ok == 1 ))
}

write_unsafe_latch() {
    local reason="$1" detail="$2" temporary_latch move_result
    temporary_latch="$unsafe_latch_file.$test_id.watchdog.tmp"
    {
        /usr/bin/printf 'state\tunsafe-reboot-required\n'
        /usr/bin/printf 'boot_session_id\t%s\n' "$boot_session_id"
        /usr/bin/printf 'test_id\t%s\n' "$test_id"
        /usr/bin/printf 'detected_at\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        /usr/bin/printf 'reason\t%s\n' "$reason"
        /usr/bin/printf 'detail\t%s\n' "${detail//$'\n'/ }"
        /usr/bin/printf 'required_action\tKeep filtering disabled; use the safe in-app enforcement reset, or restart this Mac if reset cannot prove recovery, before another live smoke test.\n'
    } > "$temporary_latch"
    if ! acquire_unsafe_latch_lock 2; then
        /bin/mv -f "$temporary_latch" "$report_directory/watchdog-unsafe-latch-lock-timeout.tsv" 2>/dev/null || true
        print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) unsafe_latch_write_failed id=$test_id reason=$reason failure=lock-timeout"
        return 1
    fi
    /bin/mv -f "$temporary_latch" "$unsafe_latch_file"
    move_result=$?
    if (( move_result == 0 )); then
        /bin/cp "$unsafe_latch_file" "$report_directory/unsafe-reboot-required.tsv" 2>/dev/null || true
    fi
    release_unsafe_latch_lock
    if (( move_result != 0 )); then
        print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) unsafe_latch_write_failed id=$test_id reason=$reason failure=rename"
        return 1
    fi
    return 0
}

print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) watchdog_armed id=$test_id deadline_epoch=$deadline_epoch"
touch "$armed_file"

while (( $(date +%s) < deadline_epoch )); do
    if [[ -e "$completed_file" ]]; then
        print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) watchdog_disarmed id=$test_id reason=runner-recovered"
        exit 0
    fi
    sleep 0.5
done

print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) hard_deadline_reached id=$test_id action=disable"
attempt=0
/usr/bin/printf 'observed_at\tdns_ok\thttps_ok\tdns_exit\thttps_exit\tdns_detail\thttps_detail\n' \
    > "$recovery_log"
while (( $(date +%s) <= recovery_deadline_epoch )); do
    attempt=$(( attempt + 1 ))
    # The runner and watchdog can discover the same outage independently. If
    # the runner has already written this run's latch, every watchdog recovery
    # launch must preserve the app's same-boot reset UI marker.
    if [[ -r "$unsafe_latch_file" ]]; then
        unsafe_condition_observed=1
    fi
    if (( attempt == 1 || attempt % 3 == 1 )); then
        request_disable "watchdog-recovery-$attempt" "$unsafe_condition_observed"
    fi
    sleep 0.5
    if blocking_disable_is_persisted; then disable_persisted=1; else disable_persisted=0; fi
    if control_connectivity_is_healthy; then control_ok=1; else control_ok=0; fi
    print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) watchdog_recovery_check id=$test_id attempt=$attempt disable_persisted=$disable_persisted control_ok=$control_ok"
    if (( disable_persisted == 1 && control_ok == 1 )); then
        /usr/bin/printf 'watchdog_recovered\t%s\tattempt=%s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$attempt" > "$completed_file"
        print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) watchdog_recovery_complete id=$test_id attempts=$attempt"
        exit 0
    fi
    if (( control_ok == 0 )); then
        if (( unsafe_condition_observed == 0 )); then
            unsafe_condition_observed=1
            write_unsafe_latch watchdog-control-connectivity-lost \
                "The independent watchdog observed failed DNS or pre-resolved HTTPS after emergency disable."
            request_disable watchdog-control-connectivity-lost 1
        fi
    fi
    sleep 0.5
done

write_unsafe_latch watchdog-recovery-deadline-exceeded \
    "Disable persistence, DNS, and pre-resolved HTTPS did not all recover before the bounded watchdog deadline."
request_disable watchdog-recovery-deadline-exceeded 1
/usr/bin/printf 'watchdog_unsafe_reboot_required\t%s\tattempts=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$attempt" > "$completed_file"
print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) watchdog_recovery_failed id=$test_id attempts=$attempt unsafe_latch=$unsafe_latch_file"
exit 75
