#!/bin/zsh

# Runs one bounded live Network Extension connectivity test. Safety is owned by
# a separate watchdog process that relaunches the app in emergency-disable mode
# at the absolute deadline even if this runner or the tested app exits.

set -u

duration_seconds="${1:-15}"
if ! [[ "$duration_seconds" == <-> ]] || (( duration_seconds < 5 || duration_seconds > 30 )); then
    print -u2 -- "Duration must be an integer from 5 through 30 seconds."
    exit 64
fi

script_directory="${0:A:h}"
project_directory="${script_directory:h}"
app_path="${HOLDFAST_APP:-/Applications/Holdfast.app}"
system_extension_bundle_id="com.GabrielPrice.ExecutiveDysfunction.WebFilter"
deployed_system_extension_info_plist="$app_path/Contents/Library/SystemExtensions/$system_extension_bundle_id.systemextension/Contents/Info.plist"
watchdog="$script_directory/mac-filter-smoke-watchdog.zsh"
test_id="$(uuidgen)"
report_directory="$project_directory/Diagnostics/SmokeTests/$test_id"
armed_file="$report_directory/watchdog-armed"
completed_file="$report_directory/watchdog-completed"
probes_file="$report_directory/probes.tsv"
control_probes_file="$report_directory/control-connectivity.tsv"
control_components_directory="$report_directory/control-connectivity-components"
same_boot_reset_receipt_audit_file="$report_directory/same-boot-reset-receipt.tsv"
unsafe_latch_file="$project_directory/Diagnostics/SmokeTests/UNSAFE-REBOOT-REQUIRED.tsv"
unsafe_latch_lock_file="$unsafe_latch_file.lock"
unsafe_latch_validation_snapshot_file="$report_directory/unsafe-latch-validation-snapshot.tsv"
enforcement_safety_reporter="$app_path/Contents/MacOS/Holdfast"
system_extension_listing_file="$report_directory/systemextensionsctl-list.txt"
system_extension_matches_file="$report_directory/system-extension-matches.txt"
system_extension_preflight_file="$report_directory/system-extension-preflight.tsv"
status_file="/Library/Application Support/ExecutiveDysfunction/filter-status.json"
policy_file="$HOME/Library/Group Containers/group.com.GabrielPrice.ExecutiveDysfunction/desktop-enforcement-policy.json"
candidate_addresses_file="$report_directory/blocked-candidate-addresses.tsv"
ready_status_file="$report_directory/filter-status-ready.json"
normal_completion=0
blocked_probe_override="${EXECUTIVE_DYSFUNCTION_BLOCKED_PROBE_DOMAIN:-}"
blocked_probe_domain=""
blocked_probe_address=""
coverage_probe_domain=""
allowed_tcp_probe_address=""
control_https_probe_address=""
baseline_provider_session=""
baseline_provider_started_at=""
ready_provider_session=""
ready_provider_started_at=""
ready_provider_build=""
ready_retry_guard_coverage=0
control_outage_detected=0
control_outage_reason=""
same_boot_reset_receipt_failure_reason=""
unsafe_latch_snapshot_failure_reason=""
unsafe_latch_lock_fd=""
enforcement_safety_snapshot_sequence=0
enforcement_safety_snapshot_file=""
enforcement_safety_blocking_disabled=""
enforcement_safety_activation_latch_set=""
enforcement_safety_receipt_attempt=""
enforcement_safety_receipt_boot=""
enforcement_safety_receipt_completed_at=""
readiness_control_failure_streak=0
recovery_succeeded=0
recovery_attempt_count=0
last_control_dns_ok=0
last_control_https_ok=0
typeset -aU blocked_probe_candidates

mkdir -p "$report_directory" "$control_components_directory"
/usr/bin/printf 'observed_at\tphase\tattempt\tdns_status\thttps_status\tdns_detail\thttps_detail\n' \
    > "$control_probes_file"

current_boot_session_id="$(/usr/sbin/sysctl -n kern.bootsessionuuid 2>/dev/null || true)"
if [[ -z "$current_boot_session_id" ]]; then
    current_boot_session_id="$(/usr/sbin/sysctl -n kern.boottime 2>/dev/null || print -r -- unknown)"
fi

request_disable() {
    local reason="$1" mark_startup_unsafe="${2:-0}" launch_result
    pkill -x Holdfast >/dev/null 2>&1 || true
    if [[ "$mark_startup_unsafe" == "1" ]]; then
        open -na "$app_path" --args \
            --disable-web-filter-now --mark-filter-startup-unsafe >/dev/null 2>&1
    else
        open -na "$app_path" --args --disable-web-filter-now >/dev/null 2>&1
    fi
    launch_result=$?
    print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) disable_requested reason=$reason mark_startup_unsafe=$mark_startup_unsafe launch_result=$launch_result" \
        >> "$report_directory/runner.log"
    return 0
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

snapshot_unsafe_latch_for_validation() {
    local copy_result
    unsafe_latch_snapshot_failure_reason=""
    if ! acquire_unsafe_latch_lock 2; then
        unsafe_latch_snapshot_failure_reason="unsafe-latch-lock-timeout"
        return 1
    fi
    if [[ ! -e "$unsafe_latch_file" ]]; then
        unsafe_latch_snapshot_failure_reason="unsafe-latch-disappeared-before-snapshot"
        release_unsafe_latch_lock
        return 1
    fi
    if [[ ! -r "$unsafe_latch_file" ]]; then
        unsafe_latch_snapshot_failure_reason="unsafe-latch-unreadable"
        release_unsafe_latch_lock
        return 1
    fi
    /bin/cp "$unsafe_latch_file" "$unsafe_latch_validation_snapshot_file"
    copy_result=$?
    release_unsafe_latch_lock
    if (( copy_result != 0 )); then
        unsafe_latch_snapshot_failure_reason="unsafe-latch-snapshot-copy-failed"
        return 1
    fi
    return 0
}

# Compare the complete, locked latch snapshot and move only that exact file.
# Every writer uses the same advisory lock, so replacement cannot occur between
# the identity check and rename.
archive_exact_unsafe_latch_snapshot() {
    local destination="$1" move_result
    if ! acquire_unsafe_latch_lock 2; then
        unsafe_latch_snapshot_failure_reason="unsafe-latch-lock-timeout"
        return 1
    fi
    if [[ ! -r "$unsafe_latch_file" ]] \
        || ! /usr/bin/cmp -s "$unsafe_latch_validation_snapshot_file" "$unsafe_latch_file"; then
        unsafe_latch_snapshot_failure_reason="unsafe-latch-changed-after-snapshot"
        release_unsafe_latch_lock
        return 1
    fi
    /bin/mv "$unsafe_latch_file" "$destination"
    move_result=$?
    release_unsafe_latch_lock
    if (( move_result != 0 )); then
        unsafe_latch_snapshot_failure_reason="unsafe-latch-archive-failed"
        return 1
    fi
    return 0
}

write_unsafe_latch() {
    local reason="$1" detail="$2" temporary_latch move_result
    temporary_latch="$unsafe_latch_file.$test_id.tmp"
    {
        /usr/bin/printf 'state\tunsafe-reboot-required\n'
        /usr/bin/printf 'boot_session_id\t%s\n' "$current_boot_session_id"
        /usr/bin/printf 'test_id\t%s\n' "$test_id"
        /usr/bin/printf 'detected_at\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        /usr/bin/printf 'reason\t%s\n' "$reason"
        /usr/bin/printf 'detail\t%s\n' "${detail//$'\n'/ }"
        /usr/bin/printf 'required_action\tKeep filtering disabled; use the safe in-app enforcement reset, or restart this Mac if reset cannot prove recovery, before another live smoke test.\n'
    } > "$temporary_latch"
    if ! acquire_unsafe_latch_lock 2; then
        /bin/mv -f "$temporary_latch" "$report_directory/unsafe-latch-lock-timeout.tsv" 2>/dev/null || true
        print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) unsafe_latch_write_failed reason=$reason failure=lock-timeout" \
            >> "$report_directory/runner.log"
        return 1
    fi
    /bin/mv -f "$temporary_latch" "$unsafe_latch_file"
    move_result=$?
    if (( move_result == 0 )); then
        /bin/cp "$unsafe_latch_file" "$report_directory/unsafe-reboot-required.tsv" 2>/dev/null || true
    fi
    release_unsafe_latch_lock
    if (( move_result != 0 )); then
        print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) unsafe_latch_write_failed reason=$reason failure=rename" \
            >> "$report_directory/runner.log"
        return 1
    fi
    print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) unsafe_latch_set reason=$reason path=$unsafe_latch_file" \
        >> "$report_directory/runner.log"
    return 0
}

probe_control_dns_component() {
    local destination="$1" timestamp output result ok=0
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    output="$(/usr/bin/dig +time=1 +tries=1 +short example.com A 2>&1)"
    result=$?
    if (( result == 0 )) && print -r -- "$output" | /usr/bin/grep -Eq \
        '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        ok=1
    fi
    output="${output//$'\n'/,}"
    /usr/bin/printf '%s\t%s\t%s\t%s\n' "$timestamp" "$ok" "$result" "$output" > "$destination"
    (( ok == 1 ))
}

probe_control_https_component() {
    local destination="$1" timestamp output result ok=0
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ -n "$control_https_probe_address" ]]; then
        output="$(curl --connect-timeout 1 --max-time 2 -sS -o /dev/null \
            --resolve "example.com:443:$control_https_probe_address" \
            -w 'http=%{http_code},connect=%{time_connect},tls=%{time_appconnect},total=%{time_total}' \
            https://example.com 2>&1)"
        result=$?
        if (( result == 0 )) && [[ "$output" == *"http=200"* ]]; then
            ok=1
        fi
    else
        output="baseline example.com address unavailable"
        result=69
    fi
    output="${output//$'\n'/ }"
    /usr/bin/printf '%s\t%s\t%s\t%s\n' "$timestamp" "$ok" "$result" "$output" > "$destination"
    (( ok == 1 ))
}

# A DNS probe and a pre-resolved HTTPS probe run concurrently. Requiring both
# catches the observed failure mode (DNS and all TCP held before the provider
# starts) without mistaking a DNS-only result for healthy Internet access.
run_control_connectivity_probe() {
    local phase="$1" attempt="$2" dns_file https_file dns_pid https_pid
    local dns_result https_result dns_detail https_detail timestamp
    dns_file="$control_components_directory/$phase-$attempt-dns.tsv"
    https_file="$control_components_directory/$phase-$attempt-https.tsv"
    probe_control_dns_component "$dns_file" &
    dns_pid=$!
    probe_control_https_component "$https_file" &
    https_pid=$!
    wait "$dns_pid"
    dns_result=$?
    wait "$https_pid"
    https_result=$?
    if (( dns_result == 0 )); then last_control_dns_ok=1; else last_control_dns_ok=0; fi
    if (( https_result == 0 )); then last_control_https_ok=1; else last_control_https_ok=0; fi
    dns_detail="$(<"$dns_file")"
    https_detail="$(<"$https_file")"
    dns_detail="${dns_detail//$'\t'/,}"
    https_detail="${https_detail//$'\t'/,}"
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    /usr/bin/printf '%s\t%s\t%s\tdns_ok=%s\thttps_ok=%s\tdns={%s}\thttps={%s}\n' \
        "$timestamp" "$phase" "$attempt" "$last_control_dns_ok" "$last_control_https_ok" \
        "$dns_detail" "$https_detail" >> "$control_probes_file"
    (( last_control_dns_ok == 1 && last_control_https_ok == 1 ))
}

# Invoke the signed app's read-only reporter under an inherited SIGALRM. The
# reporter exits before constructing MacAppModel or touching NetworkExtension;
# a wedged preferences service becomes a bounded, fail-closed observation.
load_enforcement_safety_snapshot() {
    local phase="$1" output_file temporary_file stderr_file reporter_result
    enforcement_safety_snapshot_sequence=$(( enforcement_safety_snapshot_sequence + 1 ))
    output_file="$report_directory/enforcement-safety-$phase-$enforcement_safety_snapshot_sequence.json"
    temporary_file="$output_file.tmp"
    stderr_file="$output_file.stderr"

    /usr/bin/perl -e 'alarm shift; exec @ARGV; exit 127' \
        3 "$enforcement_safety_reporter" --report-enforcement-safety-state \
        > "$temporary_file" 2> "$stderr_file"
    reporter_result=$?
    if (( reporter_result != 0 )); then
        /bin/mv -f "$temporary_file" "$output_file.failed" 2>/dev/null || true
        print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) enforcement_safety_report_failed phase=$phase exit=$reporter_result timeout_seconds=3" \
            >> "$report_directory/runner.log"
        return 1
    fi
    if ! /usr/bin/jq -e \
        'type == "object" and (.blockingDisabled | type == "boolean") and (.activationSafetyLatchSet | type == "boolean")' \
        "$temporary_file" >/dev/null 2>&1; then
        /bin/mv -f "$temporary_file" "$output_file.invalid" 2>/dev/null || true
        print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) enforcement_safety_report_failed phase=$phase failure=invalid-json-or-schema" \
            >> "$report_directory/runner.log"
        return 1
    fi
    /bin/mv -f "$temporary_file" "$output_file"
    enforcement_safety_snapshot_file="$output_file"
    enforcement_safety_blocking_disabled="$(/usr/bin/jq -r '.blockingDisabled' "$output_file" 2>/dev/null || true)"
    enforcement_safety_activation_latch_set="$(/usr/bin/jq -r '.activationSafetyLatchSet' "$output_file" 2>/dev/null || true)"
    enforcement_safety_receipt_attempt="$(/usr/bin/jq -r '.sameBootResetReceipt.attemptIdentifier // empty' "$output_file" 2>/dev/null || true)"
    enforcement_safety_receipt_boot="$(/usr/bin/jq -r '.sameBootResetReceipt.bootSessionIdentifier // empty' "$output_file" 2>/dev/null || true)"
    enforcement_safety_receipt_completed_at="$(/usr/bin/jq -r '.sameBootResetReceipt.completedAtEpochSeconds // empty' "$output_file" 2>/dev/null || true)"
    if [[ "$enforcement_safety_blocking_disabled" != "true" \
        && "$enforcement_safety_blocking_disabled" != "false" ]] \
        || [[ "$enforcement_safety_activation_latch_set" != "true" \
        && "$enforcement_safety_activation_latch_set" != "false" ]]; then
        print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) enforcement_safety_report_failed phase=$phase failure=missing-required-booleans" \
            >> "$report_directory/runner.log"
        return 1
    fi
    return 0
}

blocking_disable_is_persisted() {
    load_enforcement_safety_snapshot disabled-check \
        && [[ "$enforcement_safety_blocking_disabled" == "true" ]]
}

refresh_control_https_probe_address() {
    control_https_probe_address="$(/usr/bin/dig +time=1 +tries=1 +short example.com A 2>/dev/null \
        | /usr/bin/awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/{print; exit}')"
    [[ -n "$control_https_probe_address" ]]
}

numeric_timestamp_is_later() {
    local candidate="$1" reference="$2"
    /usr/bin/awk -v candidate="$candidate" -v reference="$reference" '
        BEGIN {
            numeric = "^[0-9]+([.][0-9]+)?$"
            if (candidate !~ numeric || reference !~ numeric) exit 2
            exit !((candidate + 0) > (reference + 0))
        }
    '
}

# The app writes this receipt only after keeping disabled intent set, draining
# old preference operations, proving the NE preference absent, observing fresh
# DNS/HTTPS connectivity, and proving absence once more. The harness still
# independently binds that receipt to this boot and this latch, then requires
# two new control-connectivity rounds before retiring its own interlock.
retire_current_boot_unsafe_latch_from_reset_receipt() {
    local latch_detected_at latch_detected_epoch receipt_boot receipt_completed_at
    local receipt_attempt receipt_latch_set round reporter_ok=0

    latch_detected_at="$(/usr/bin/awk -F '\t' \
        '$1 == "detected_at" { print $2; exit }' "$unsafe_latch_validation_snapshot_file")"
    latch_detected_epoch="$(LC_ALL=C /bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' \
        "$latch_detected_at" '+%s' 2>/dev/null || true)"
    if load_enforcement_safety_snapshot same-boot-reset-receipt; then
        reporter_ok=1
    fi
    receipt_boot="$enforcement_safety_receipt_boot"
    receipt_completed_at="$enforcement_safety_receipt_completed_at"
    receipt_attempt="$enforcement_safety_receipt_attempt"
    receipt_latch_set="$enforcement_safety_activation_latch_set"

    {
        /usr/bin/printf 'latch_boot_session\t%s\n' "$current_boot_session_id"
        /usr/bin/printf 'latch_detected_at\t%s\n' "$latch_detected_at"
        /usr/bin/printf 'latch_detected_epoch\t%s\n' "$latch_detected_epoch"
        /usr/bin/printf 'receipt_boot_session\t%s\n' "$receipt_boot"
        /usr/bin/printf 'receipt_completed_at\t%s\n' "$receipt_completed_at"
        /usr/bin/printf 'receipt_attempt\t%s\n' "$receipt_attempt"
        /usr/bin/printf 'receipt_activation_safety_latch_set\t%s\n' "$receipt_latch_set"
        /usr/bin/printf 'reporter_snapshot\t%s\n' "$enforcement_safety_snapshot_file"
    } > "$same_boot_reset_receipt_audit_file"

    if (( reporter_ok == 0 )); then
        same_boot_reset_receipt_failure_reason="enforcement-safety-reporter-failed"
    elif [[ "$enforcement_safety_blocking_disabled" != "true" ]]; then
        same_boot_reset_receipt_failure_reason="blocking-disabled-not-persisted-before-probes"
    elif [[ "$receipt_latch_set" != "false" ]]; then
        same_boot_reset_receipt_failure_reason="application-safety-latch-still-set"
    elif [[ -z "$receipt_boot" || "$receipt_boot" != "$current_boot_session_id" ]]; then
        same_boot_reset_receipt_failure_reason="receipt-boot-mismatch"
    elif [[ -z "$receipt_attempt" ]]; then
        same_boot_reset_receipt_failure_reason="receipt-attempt-missing"
    elif [[ -z "$latch_detected_epoch" ]] \
        || ! numeric_timestamp_is_later "$receipt_completed_at" "$latch_detected_epoch"; then
        same_boot_reset_receipt_failure_reason="receipt-not-newer-than-latch"
    else
        same_boot_reset_receipt_failure_reason=""
    fi

    if [[ -n "$same_boot_reset_receipt_failure_reason" ]]; then
        /usr/bin/printf 'validation\trefused\t%s\n' \
            "$same_boot_reset_receipt_failure_reason" >> "$same_boot_reset_receipt_audit_file"
        return 1
    fi

    for round in 1 2; do
        if ! refresh_control_https_probe_address; then
            same_boot_reset_receipt_failure_reason="receipt-connectivity-round-$round-address-unavailable"
            /usr/bin/printf 'validation\trefused\t%s\n' \
                "$same_boot_reset_receipt_failure_reason" >> "$same_boot_reset_receipt_audit_file"
            return 1
        fi
        if ! run_control_connectivity_probe same-boot-reset-receipt "$round"; then
            same_boot_reset_receipt_failure_reason="receipt-connectivity-round-$round-failed"
            /usr/bin/printf 'validation\trefused\t%s\n' \
                "$same_boot_reset_receipt_failure_reason" >> "$same_boot_reset_receipt_audit_file"
            return 1
        fi
        if ! load_enforcement_safety_snapshot "same-boot-reset-receipt-round-$round"; then
            same_boot_reset_receipt_failure_reason="receipt-state-round-$round-reporter-failed"
            /usr/bin/printf 'validation\trefused\t%s\n' \
                "$same_boot_reset_receipt_failure_reason" >> "$same_boot_reset_receipt_audit_file"
            return 1
        fi
        if [[ "$enforcement_safety_blocking_disabled" != "true" ]]; then
            same_boot_reset_receipt_failure_reason="blocking-disabled-lost-during-receipt-probes"
        elif [[ "$enforcement_safety_activation_latch_set" != "false" ]]; then
            same_boot_reset_receipt_failure_reason="application-safety-latch-set-during-receipt-probes"
        elif [[ "$enforcement_safety_receipt_attempt" != "$receipt_attempt" \
            || "$enforcement_safety_receipt_boot" != "$receipt_boot" \
            || "$enforcement_safety_receipt_completed_at" != "$receipt_completed_at" ]]; then
            same_boot_reset_receipt_failure_reason="receipt-changed-during-connectivity-probes"
        else
            same_boot_reset_receipt_failure_reason=""
        fi
        if [[ -n "$same_boot_reset_receipt_failure_reason" ]]; then
            /usr/bin/printf 'validation\trefused\t%s\n' \
                "$same_boot_reset_receipt_failure_reason" >> "$same_boot_reset_receipt_audit_file"
            return 1
        fi
        (( round == 1 )) && sleep 0.5
    done

    if ! archive_exact_unsafe_latch_snapshot \
        "$report_directory/retired-current-boot-unsafe-latch.tsv"; then
        same_boot_reset_receipt_failure_reason="$unsafe_latch_snapshot_failure_reason"
        /usr/bin/printf 'validation\trefused\t%s\n' \
            "$same_boot_reset_receipt_failure_reason" >> "$same_boot_reset_receipt_audit_file"
        return 1
    fi
    /usr/bin/printf 'validation\taccepted\ttwo-fresh-dns-https-rounds-and-disabled-intent-confirmed\n' \
        >> "$same_boot_reset_receipt_audit_file"
    print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) unsafe_latch_retired reason=same-boot-reset-receipt attempt=$receipt_attempt" \
        >> "$report_directory/runner.log"
    return 0
}

# Writes every line for the deployed WebFilter build to the match file. Exit 0
# means at least one such line has both enabled/active column markers and the
# authoritative `[activated enabled]` state. Exit 2 means no deployed-build
# line; exit 3 means matching lines exist but none is usable. Matching uses the
# `(marketing-version/build)` suffix rather than field positions because the
# leading enabled/active columns are blank and systemextensionsctl varies tabs.
parse_system_extension_listing() {
    local listing_file="$1" deployed_build_number="$2" matches_file="$3"
    /usr/bin/awk \
        -v bundle="$system_extension_bundle_id" \
        -v build="$deployed_build_number" '
        {
            line = $0
            sub(/\r$/, "", line)
            bundlePosition = index(line, bundle)
            if (bundlePosition == 0) next
            suffix = substr(line, bundlePosition + length(bundle))
            sub(/^[[:space:]]+/, "", suffix)
            if (substr(suffix, 1, 1) != "(") next
            closingPosition = index(suffix, ")")
            if (closingPosition == 0) next
            versionField = substr(suffix, 1, closingPosition)
            gsub(/[[:space:]]/, "", versionField)
            if (index(versionField, "/" build ")") == 0) next

            print line
            matches += 1
            prefix = substr(line, 1, bundlePosition - 1)
            markerCount = gsub(/\*/, "", prefix)
            stateIsReady = line ~ /\[[[:space:]]*activated[[:space:]]+enabled[[:space:]]*\][[:space:]]*$/
            if (markerCount >= 2 && stateIsReady) healthy = 1
        }
        END {
            if (matches == 0) exit 2
            if (!healthy) exit 3
        }
    ' "$listing_file" > "$matches_file"
}

# During deployment, the app bundle can legitimately be one build newer than
# the registered extension. With an explicit opt-in, accept only an older
# enabled/active instance of the same bundle as the source for a guarded
# replacement. The later readiness gate still requires a fresh provider session
# whose build exactly matches the deployed app before probes are graded.
parse_system_extension_upgrade_source() {
    local listing_file="$1" deployed_build_number="$2" matches_file="$3"
    /usr/bin/awk \
        -v bundle="$system_extension_bundle_id" \
        -v deployedBuild="$deployed_build_number" '
        {
            line = $0
            sub(/\r$/, "", line)
            bundlePosition = index(line, bundle)
            if (bundlePosition == 0) next
            suffix = substr(line, bundlePosition + length(bundle))
            sub(/^[[:space:]]+/, "", suffix)
            if (substr(suffix, 1, 1) != "(") next
            closingPosition = index(suffix, ")")
            if (closingPosition == 0) next
            versionField = substr(suffix, 1, closingPosition)
            split(versionField, versionParts, "/")
            sourceBuild = versionParts[2] + 0

            prefix = substr(line, 1, bundlePosition - 1)
            markerCount = gsub(/\*/, "", prefix)
            stateIsReady = line ~ /\[[[:space:]]*activated[[:space:]]+enabled[[:space:]]*\][[:space:]]*$/
            if (markerCount >= 2 && stateIsReady && sourceBuild > 0 && sourceBuild < deployedBuild + 0) {
                print line
                healthy += 1
            }
        }
        END { if (!healthy) exit 2 }
    ' "$listing_file" > "$matches_file"
}

run_system_extension_preflight() {
    local deployed_build_number="$1" listing_output list_result parse_result match_count
    local preflight_state preflight_reason matching_line
    listing_output="$(/usr/bin/systemextensionsctl list 2>&1)"
    list_result=$?
    print -r -- "$listing_output" > "$system_extension_listing_file"
    : > "$system_extension_matches_file"

    if (( list_result != 0 )); then
        parse_result=69
        preflight_state="refused"
        preflight_reason="systemextensionsctl-list-failed"
    elif [[ -z "$deployed_build_number" ]]; then
        parse_result=64
        preflight_state="refused"
        preflight_reason="deployed-build-unavailable"
    else
        parse_system_extension_listing "$system_extension_listing_file" \
            "$deployed_build_number" "$system_extension_matches_file"
        parse_result=$?
        if (( parse_result != 0 )) \
            && [[ "${EXECUTIVE_DYSFUNCTION_ALLOW_EXTENSION_UPGRADE:-0}" == "1" ]]; then
            parse_system_extension_upgrade_source "$system_extension_listing_file" \
                "$deployed_build_number" "$system_extension_matches_file"
            if (( $? == 0 )); then
                parse_result=0
                preflight_state="enabled-active-upgrade-source"
                preflight_reason="older-enabled-build-ready-for-guarded-replacement"
            fi
        fi
        case "$parse_result" in
            0)
                if [[ -z "${preflight_state:-}" ]]; then
                    preflight_state="enabled-active"
                    preflight_reason="deployed-build-ready"
                fi
                ;;
            2)
                preflight_state="refused"
                preflight_reason="deployed-build-not-registered"
                ;;
            *)
                preflight_state="refused"
                preflight_reason="deployed-build-not-enabled-active"
                ;;
        esac
    fi

    match_count="$(/usr/bin/awk 'END { print NR + 0 }' "$system_extension_matches_file")"
    {
        /usr/bin/printf 'bundle_id\t%s\n' "$system_extension_bundle_id"
        /usr/bin/printf 'deployed_app_build\t%s\n' "$deployed_build"
        /usr/bin/printf 'deployed_extension_build\t%s\n' "$deployed_build_number"
        /usr/bin/printf 'list_exit\t%s\n' "$list_result"
        /usr/bin/printf 'parse_exit\t%s\n' "$parse_result"
        /usr/bin/printf 'matching_line_count\t%s\n' "$match_count"
        /usr/bin/printf 'observed_state\t%s\n' "$preflight_state"
        /usr/bin/printf 'reason\t%s\n' "$preflight_reason"
        while IFS= read -r matching_line; do
            /usr/bin/printf 'matching_line\t%s\n' "$matching_line"
        done < "$system_extension_matches_file"
    } > "$system_extension_preflight_file"
    print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) system_extension_preflight state=$preflight_state reason=$preflight_reason deployed_build=$deployed_build_number matches=$match_count list_exit=$list_result parse_exit=$parse_result" \
        >> "$report_directory/runner.log"

    [[ "$preflight_state" == "enabled-active" \
        || "$preflight_state" == "enabled-active-upgrade-source" ]]
}

emergency_disable() {
    if (( normal_completion == 0 )); then
        request_disable runner-exit-failsafe "$control_outage_detected"
    fi
}
trap emergency_disable EXIT

if [[ ! -d "$app_path" || ! -x "$app_path/Contents/MacOS/Holdfast" ]]; then
    print -u2 -- "Deployed app is missing: $app_path"
    exit 66
fi

# Build 45 introduced the early-exit reporter. Passing its flag to an older
# app would instead construct MacAppModel and could touch NetworkExtension, so
# reject old/unknown builds before the first reporter invocation.
safety_reporter_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$app_path/Contents/Info.plist" 2>/dev/null || true)"
if ! [[ "$safety_reporter_build" == <-> ]] || (( safety_reporter_build < 45 )); then
    {
        print -r -- "Holdfast macOS filter smoke-test audit"
        print -r -- "REFUSED deployed app does not advertise the read-only safety reporter."
        print -r -- "Observed build: ${safety_reporter_build:-unknown}; required build: 45 or newer."
        print -r -- "No reporter was invoked, no watchdog was armed, and no live enable was attempted."
    } > "$report_directory/summary.txt"
    print -u2 -- "Live smoke test refused: deployed build ${safety_reporter_build:-unknown} predates the safe reporter."
    print -u2 -- "Report: $report_directory/summary.txt"
    exit 78
fi

# A connectivity outage during a live test latches this boot as unsafe. A
# second enable attempt against the same wedged Network Extension stack is not
# useful and can strand the machine offline again. A different boot retires the
# latch automatically. On the same boot, only a newer app-authored safe-reset
# receipt plus two fresh harness connectivity rounds may retire it.
if [[ -e "$unsafe_latch_file" ]]; then
    if ! snapshot_unsafe_latch_for_validation; then
        {
            print -r -- "Holdfast macOS filter smoke-test audit"
            print -r -- "REFUSED the unsafe/reboot-required latch could not be locked and snapshotted."
            print -r -- "Failure: $unsafe_latch_snapshot_failure_reason"
            print -r -- "Keep filtering disabled; resolve the latch error before attempting either safe reset validation or another live smoke test."
            print -r -- "Latch: $unsafe_latch_file"
        } > "$report_directory/summary.txt"
        print -u2 -- "Live smoke test refused: the safety latch could not be snapshotted ($unsafe_latch_snapshot_failure_reason)."
        print -u2 -- "Report: $report_directory/summary.txt"
        exit 75
    fi
    latched_boot_session_id="$(/usr/bin/awk -F '\t' \
        '$1 == "boot_session_id" { print $2; exit }' "$unsafe_latch_validation_snapshot_file")"
    if [[ -z "$latched_boot_session_id" \
        || "$latched_boot_session_id" == "unknown" \
        || "$current_boot_session_id" == "unknown" \
        || "$latched_boot_session_id" == "$current_boot_session_id" ]]; then
        if [[ -n "$latched_boot_session_id" \
            && "$latched_boot_session_id" != "unknown" \
            && "$current_boot_session_id" != "unknown" \
            && "$latched_boot_session_id" == "$current_boot_session_id" ]] \
            && retire_current_boot_unsafe_latch_from_reset_receipt; then
            print -r -- "Accepted safe same-boot reset receipt; filtering remains disabled."
        else
            /bin/cp "$unsafe_latch_validation_snapshot_file" "$report_directory/unsafe-reboot-required.tsv" 2>/dev/null || true
            [[ -n "$same_boot_reset_receipt_failure_reason" ]] \
                || same_boot_reset_receipt_failure_reason="boot-session-unavailable-or-mismatched"
            {
                print -r -- "Holdfast macOS filter smoke-test audit"
                print -r -- "REFUSED unsafe-reboot-required latch is active for this boot."
                print -r -- "Keep filtering disabled. Use the app's safe enforcement reset; if it cannot prove recovery, restart this Mac before another live smoke test."
                print -r -- "Receipt validation: $same_boot_reset_receipt_failure_reason"
                print -r -- "Latch: $unsafe_latch_file"
            } > "$report_directory/summary.txt"
            print -u2 -- "Live smoke test refused: an unsafe/reboot-required latch is active for this boot."
            print -u2 -- "Safe reset receipt: $same_boot_reset_receipt_failure_reason"
            print -u2 -- "Report: $report_directory/summary.txt"
            exit 75
        fi
    elif ! archive_exact_unsafe_latch_snapshot \
        "$report_directory/previous-boot-unsafe-latch.tsv"; then
        {
            print -r -- "Holdfast macOS filter smoke-test audit"
            print -r -- "REFUSED the previous-boot safety latch changed or could not be archived safely."
            print -r -- "Failure: $unsafe_latch_snapshot_failure_reason"
            print -r -- "Filtering remains disabled; retry after the other safety process finishes."
            print -r -- "Latch: $unsafe_latch_file"
        } > "$report_directory/summary.txt"
        print -u2 -- "Live smoke test refused: previous-boot latch archive failed ($unsafe_latch_snapshot_failure_reason)."
        print -u2 -- "Report: $report_directory/summary.txt"
        exit 75
    fi
fi

deployed_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$app_path/Contents/Info.plist" 2>/dev/null || true)"
deployed_webfilter_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$deployed_system_extension_info_plist" 2>/dev/null || true)"
if ! run_system_extension_preflight "$deployed_webfilter_build"; then
    {
        print -r -- "Holdfast macOS filter smoke-test audit"
        print -r -- "REFUSED deployed WebFilter build is not both enabled and active."
        print -r -- "No watchdog was armed and no live enable was attempted."
        print -r -- "Observed state:"
        /bin/cat "$system_extension_preflight_file"
        print -r -- "Full listing: $system_extension_listing_file"
    } > "$report_directory/summary.txt"
    print -u2 -- "Live smoke test refused: deployed WebFilter build $deployed_webfilter_build is not enabled and active."
    print -u2 -- "Report: $report_directory/summary.txt"
    exit 76
fi

add_blocked_probe_candidate() {
    local candidate="${1:l}"
    if [[ -n "$candidate" && "$candidate" != *[!a-z0-9.-]* ]]; then
        blocked_probe_candidates+=("$candidate")
    fi
}

canonical_domain_suffix() {
    local value="${1:l}"
    while [[ "$value" == *. ]]; do value="${value%.}"; done
    [[ "$value" == www.* ]] && value="${value#www.}"
    print -r -- "$value"
}

# Capture every plausible explicit domain before establishing the disabled
# baseline. Build 39 deliberately clears blockedDomains when it stops, so
# choosing the probe only after that point silently scheduled zero blocked
# probes. Resolve all candidates while disabled, then select the provider's
# actually active domain after its fresh heartbeat arrives.
if [[ -n "$blocked_probe_override" ]]; then
    add_blocked_probe_candidate "$blocked_probe_override"
fi
if [[ -r "$status_file" ]]; then
    while IFS= read -r candidate; do
        add_blocked_probe_candidate "$candidate"
    done < <(jq -r '.blockedDomains[]? // empty' "$status_file" 2>/dev/null)
fi
if [[ -r "$policy_file" ]]; then
    while IFS= read -r candidate; do
        add_blocked_probe_candidate "$candidate"
    done < <(jq -r \
        '.policy.rules[]?
            | select(.enforcementMode == "blockList" and .isEnabled == true)
            | .domains[]? // empty' \
        "$policy_file" 2>/dev/null)
fi

# Establish a known-safe baseline before arming the test.
pkill -x Holdfast >/dev/null 2>&1 || true
open -na "$app_path" --args --disable-web-filter-now
sleep 1
for _ in {1..30}; do
    /usr/bin/grep -qF '# BEGIN Holdfast block page' /etc/hosts 2>/dev/null \
        || /usr/bin/grep -qF '# BEGIN ExecutiveDysfunction block page' /etc/hosts 2>/dev/null \
        || break
    sleep 0.1
done

start_epoch="$(date +%s)"
deadline_epoch="$(( start_epoch + duration_seconds ))"
deadline_ms="$(( deadline_epoch * 1000 ))"
start_local="$(date '+%Y-%m-%d %H:%M:%S')"

{
    print -r -- "test_id\t$test_id"
    print -r -- "app_path\t$app_path"
    print -r -- "app_build\t$deployed_build"
    print -r -- "webfilter_build\t$deployed_webfilter_build"
    print -r -- "start_epoch\t$start_epoch"
    print -r -- "hard_deadline_epoch\t$deadline_epoch"
    print -r -- "duration_seconds\t$duration_seconds"
} > "$report_directory/metadata.tsv"

scutil --nwi > "$report_directory/network-before.txt" 2>&1 || true
if [[ -r "$status_file" ]]; then
    cp "$status_file" "$report_directory/filter-status-before.json"
    baseline_provider_session="$(jq -r '.diagnostics.sessionID // empty' \
        "$report_directory/filter-status-before.json" 2>/dev/null)"
    baseline_provider_started_at="$(jq -r '.diagnostics.providerStartedAt // empty' \
        "$report_directory/filter-status-before.json" 2>/dev/null)"
fi
print -r -- "baseline_provider_session\t$baseline_provider_session" >> "$report_directory/metadata.tsv"
print -r -- "baseline_provider_started_at\t$baseline_provider_started_at" >> "$report_directory/metadata.tsv"
print -r -- "blocked_probe_candidate_count\t${#blocked_probe_candidates[@]}" >> "$report_directory/metadata.tsv"
: > "$candidate_addresses_file"
for candidate in "${blocked_probe_candidates[@]}"; do
    print -r -- "blocked_probe_candidate\t$candidate" >> "$report_directory/metadata.tsv"
    candidate_address="$(/usr/bin/dig +time=2 +tries=1 +short "$candidate" A 2>/dev/null \
        | /usr/bin/awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/{print; exit}')"
    if [[ -n "$candidate_address" ]]; then
        /usr/bin/printf '%s\t%s\n' "$candidate" "$candidate_address" >> "$candidate_addresses_file"
    fi
done
allowed_tcp_probe_address="$(/usr/bin/dig +time=2 +tries=1 +short www.apple.com A 2>/dev/null \
    | /usr/bin/awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/{print; exit}')"
if [[ -n "$allowed_tcp_probe_address" ]]; then
    print -r -- "allowed_tcp_probe_address\t$allowed_tcp_probe_address" >> "$report_directory/metadata.tsv"
fi
refresh_control_https_probe_address || true
print -r -- "control_https_probe_address\t$control_https_probe_address" >> "$report_directory/metadata.tsv"
if run_control_connectivity_probe baseline 1; then
    baseline_control_connectivity=1
else
    baseline_control_connectivity=0
fi
print -r -- "baseline_control_connectivity\t$baseline_control_connectivity" >> "$report_directory/metadata.tsv"
if (( baseline_control_connectivity == 0 )); then
    {
        print -r -- "Holdfast macOS filter smoke-test audit"
        print -r -- "REFUSED baseline DNS and pre-resolved HTTPS connectivity were not both healthy."
        print -r -- "Filtering was left disabled; no live enable was attempted."
        print -r -- "Report: $report_directory"
    } > "$report_directory/summary.txt"
    print -u2 -- "Baseline connectivity is not healthy; refusing to enable filtering."
    print -u2 -- "Report: $report_directory"
    exit 69
fi

/usr/bin/nohup "$watchdog" \
    "$app_path" "$deadline_epoch" "$test_id" "$armed_file" "$completed_file" \
    "$unsafe_latch_file" "$current_boot_session_id" "$control_https_probe_address" \
    "$(( deadline_epoch + 30 ))" \
    > "$report_directory/watchdog.log" 2>&1 </dev/null &
watchdog_pid=$!
print -r -- "watchdog_pid\t$watchdog_pid" >> "$report_directory/metadata.tsv"

for _ in {1..30}; do
    [[ -e "$armed_file" ]] && break
    sleep 0.1
done
if [[ ! -e "$armed_file" ]]; then
    print -u2 -- "Independent watchdog did not arm; refusing to enable filtering."
    exit 70
fi

print -r -- "timestamp\tround\tprobe\texit_code\tdetail" > "$probes_file"
print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) watchdog_ready pid=$watchdog_pid action=enable" >> "$report_directory/runner.log"

pkill -x Holdfast >/dev/null 2>&1 || true
open -na "$app_path" --args \
    --enable-web-filter-smoke-test \
    "--smoke-test-id=$test_id" \
    "--smoke-test-deadline-ms=$deadline_ms"

# A system-extension replacement and provider startup are asynchronous. Do not
# count pre-start traffic as an enforcement result. A same-build heartbeat can
# belong to the provider that was active before this run, so readiness requires
# a distinct session whose providerStartedAt is inside this guarded window.
# The first heartbeat occurs only after applySettings has completed. The hard
# watchdog deadline remains unchanged while waiting.
filter_ready=0
start_ms="$(( start_epoch * 1000 ))"
readiness_control_probe_round=0
while (( $(date +%s) < deadline_epoch - 5 )); do
    readiness_control_probe_round=$(( readiness_control_probe_round + 1 ))
    if run_control_connectivity_probe readiness "$readiness_control_probe_round"; then
        readiness_control_failure_streak=0
    else
        readiness_control_failure_streak=$(( readiness_control_failure_streak + 1 ))
        print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) readiness_control_failed round=$readiness_control_probe_round streak=$readiness_control_failure_streak" \
            >> "$report_directory/runner.log"
        if (( readiness_control_failure_streak >= 2 )); then
            control_outage_detected=1
            control_outage_reason="readiness-control-connectivity-lost"
            write_unsafe_latch "$control_outage_reason" \
                "DNS or pre-resolved HTTPS failed on two consecutive checks before provider readiness."
            request_disable "$control_outage_reason" 1
            break
        fi
    fi
    if [[ -r "$status_file" ]]; then
        cp "$status_file" "$ready_status_file" 2>/dev/null || true
    fi
    if [[ -r "$ready_status_file" ]] && jq -e \
        --arg build "$deployed_build" \
        --arg baselineSession "$baseline_provider_session" \
        --argjson startedAt "$start_ms" \
        '.diagnostics.providerBuild == $build
            and .updatedAt >= $startedAt
            and (.diagnostics.providerStartedAt // 0) >= $startedAt
            and ((.diagnostics.sessionID // "") | length) > 0
            and ($baselineSession == "" or .diagnostics.sessionID != $baselineSession)
            and (.macFilterSettings.isReady // false) == true
            and .macFilterSettings.appliedPolicyRevision == .revision
            and ((.macFilterSettings.planMode // "") != "domainRules"
                or ((.macFilterSettings.requiredRetryGuardDomainCount // 0) > 0
                    and .macFilterSettings.coveredRetryGuardDomainCount
                        == .macFilterSettings.requiredRetryGuardDomainCount
                    and (.macFilterSettings.correlatedAddressCount // 0) > 0))
            and .hasActiveWebRestrictions == true
            and (.diagnostics.heartbeatSequence // 0) >= 1' \
        "$ready_status_file" >/dev/null 2>&1; then
        filter_ready=1
        ready_provider_session="$(jq -r '.diagnostics.sessionID' "$ready_status_file")"
        ready_provider_started_at="$(jq -r '.diagnostics.providerStartedAt' "$ready_status_file")"
        ready_provider_build="$(jq -r '.diagnostics.providerBuild' "$ready_status_file")"
        break
    fi
    sleep 0.2
done
print -r -- "filter_ready\t$filter_ready" >> "$report_directory/metadata.tsv"
print -r -- "filter_ready_observed_at\t$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$report_directory/metadata.tsv"
print -r -- "ready_provider_session\t$ready_provider_session" >> "$report_directory/metadata.tsv"
print -r -- "ready_provider_started_at\t$ready_provider_started_at" >> "$report_directory/metadata.tsv"
print -r -- "ready_provider_build\t$ready_provider_build" >> "$report_directory/metadata.tsv"
if (( filter_ready == 1 )) && [[ -r "$ready_status_file" ]]; then
    normalized_override="${blocked_probe_override:l}"
    if [[ -n "$normalized_override" ]] && jq -e --arg domain "$normalized_override" \
        '(.blockedDomains // []) | index($domain) != null' \
        "$ready_status_file" >/dev/null 2>&1; then
        blocked_probe_domain="$normalized_override"
    else
        blocked_probe_domain="$(jq -r '.blockedDomains[0] // empty' "$ready_status_file" 2>/dev/null)"
    fi
fi
if [[ -n "$blocked_probe_domain" ]]; then
    coverage_probe_domain="$(canonical_domain_suffix "$blocked_probe_domain")"
    blocked_probe_address="$(/usr/bin/awk -F '\t' -v domain="$blocked_probe_domain" \
        '$1 == domain {print $2; exit}' "$candidate_addresses_file")"
    print -r -- "blocked_probe_domain\t$blocked_probe_domain" >> "$report_directory/metadata.tsv"
    if [[ -n "$blocked_probe_address" ]]; then
        print -r -- "blocked_probe_address\t$blocked_probe_address" >> "$report_directory/metadata.tsv"
    fi
    if [[ -r "$ready_status_file" ]] && jq -e --arg domain "$coverage_probe_domain" \
        '(.macFilterSettings.coveredRetryGuardDomainSuffixes // [])
            | index($domain) != null' \
        "$ready_status_file" >/dev/null 2>&1; then
        ready_retry_guard_coverage=1
    fi
fi
print -r -- "ready_retry_guard_coverage\t$ready_retry_guard_coverage" >> "$report_directory/metadata.tsv"
print -r -- "control_outage_detected\t$control_outage_detected" >> "$report_directory/metadata.tsv"
print -r -- "control_outage_reason\t$control_outage_reason" >> "$report_directory/metadata.tsv"

probe_curl() {
    local round="$1" name="$2" url="$3" destination="$4" interface_name="${5:-}"
    local timestamp output result
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local -a interface_arguments=()
    if [[ -n "$interface_name" ]]; then
        interface_arguments=(--interface "$interface_name")
    fi
    output="$(curl --connect-timeout 2 --max-time 3 -sS -o /dev/null \
        -w 'http=%{http_code},dns=%{time_namelookup},connect=%{time_connect},tls=%{time_appconnect},total=%{time_total}' \
        "${interface_arguments[@]}" "$url" 2>&1)"
    result=$?
    output="${output//$'\n'/ }"
    print -r -- "$timestamp\t$round\t$name\t$result\t$output" > "$destination"
}

probe_dns() {
    local round="$1" destination="$2" timestamp output result
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ -x /usr/bin/dig ]]; then
        output="$(/usr/bin/dig +time=2 +tries=1 +short example.com A 2>&1)"
        result=$?
    else
        output="dig unavailable"
        result=127
    fi
    output="${output//$'\n'/,}"
    print -r -- "$timestamp\t$round\tdns-example\t$result\t$output" > "$destination"
}

probe_tcp() {
    local round="$1" address="$2" destination="$3" timestamp output result
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ -n "$address" ]]; then
        output="$(/usr/bin/nc -z -G 2 "$address" 443 2>&1)"
        result=$?
        output="${output//$'\n'/ }"
        [[ -z "$output" ]] && output="connected"
    else
        result=69
        output="allowed control address unavailable"
    fi
    print -r -- "$timestamp\t$round\ttcp-allowed-apple-443\t$result\t$output" > "$destination"
}

probe_curl_resolved() {
    local round="$1" domain="$2" address="$3" destination="$4"
    local timestamp output result
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # Do not follow redirects: an HTTP response from the original cached IP is
    # itself the bypass signal, while http=000 means interception occurred
    # before the origin could answer.
    output="$(curl --connect-timeout 2 --max-time 3 -sS -o /dev/null \
        --resolve "$domain:443:$address" \
        -w 'http=%{http_code},dns=%{time_namelookup},connect=%{time_connect},tls=%{time_appconnect},total=%{time_total}' \
        "https://$domain" 2>&1)"
    result=$?
    output="${output//$'\n'/ }"
    print -r -- "$timestamp\t$round\thttps-policy-blocked-resolved\t$result\t$output" > "$destination"
}

probe_blocked_named() {
    local round="$1" domain="$2" destination="$3"
    local timestamp output result body_file message_present=0
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    body_file="${destination%.tsv}.body.html"
    output="$(curl --connect-timeout 2 --max-time 3 -sS -o "$body_file" \
        -w 'http=%{http_code},dns=%{time_namelookup},connect=%{time_connect},tls=%{time_appconnect},total=%{time_total}' \
        "https://$domain" 2>&1)"
    result=$?
    if [[ -r "$body_file" ]] && /usr/bin/grep -qF \
        'Holdfast has returned this time to you.' "$body_file"; then
        message_present=1
    fi
    output="${output//$'\n'/ },block_page_message=$message_present"
    print -r -- "$timestamp\t$round\thttps-policy-blocked\t$result\t$output" > "$destination"
}

round=0
active_control_probe_round=0
while (( control_outage_detected == 0 && $(date +%s) < deadline_epoch - 2 )); do
    active_control_probe_round=$(( active_control_probe_round + 1 ))
    if ! run_control_connectivity_probe active "$active_control_probe_round"; then
        # Confirm immediately instead of waiting for a second full diagnostic
        # round. The regular round can take three seconds because it includes
        # deliberately unreachable interface probes.
        if ! run_control_connectivity_probe active-confirm "$active_control_probe_round"; then
            control_outage_detected=1
            control_outage_reason="active-control-connectivity-lost"
            write_unsafe_latch "$control_outage_reason" \
                "DNS or pre-resolved HTTPS failed in an active probe and its immediate confirmation."
            request_disable "$control_outage_reason" 1
            break
        fi
    fi
    round=$(( round + 1 ))
    round_directory="$report_directory/round-$round"
    mkdir -p "$round_directory"
    probe_curl "$round" https-example https://example.com "$round_directory/https-example.tsv" &
    p1=$!
    probe_curl "$round" https-apple https://www.apple.com "$round_directory/https-apple.tsv" &
    p2=$!
    probe_dns "$round" "$round_directory/dns.tsv" &
    p3=$!
    probe_tcp "$round" "$allowed_tcp_probe_address" "$round_directory/tcp.tsv" &
    p4=$!
    probe_curl "$round" https-example-en0 https://example.com "$round_directory/https-example-en0.tsv" en0 &
    p5=$!
    probe_curl "$round" https-example-utun9 https://example.com "$round_directory/https-example-utun9.tsv" utun9 &
    p6=$!
    if [[ -n "$blocked_probe_domain" ]]; then
        probe_blocked_named "$round" "$blocked_probe_domain" "$round_directory/https-policy-blocked.tsv" &
        p7=$!
        if [[ -n "$blocked_probe_address" ]]; then
            probe_curl_resolved "$round" "$blocked_probe_domain" "$blocked_probe_address" "$round_directory/https-policy-blocked-resolved.tsv" &
            p8=$!
            wait "$p1" "$p2" "$p3" "$p4" "$p5" "$p6" "$p7" "$p8"
        else
            wait "$p1" "$p2" "$p3" "$p4" "$p5" "$p6" "$p7"
        fi
    else
        wait "$p1" "$p2" "$p3" "$p4" "$p5" "$p6"
    fi
    for result_file in "$round_directory"/*.tsv; do
        print -r -- "$(<"$result_file")" >> "$probes_file"
    done
    if [[ -r "$status_file" ]]; then
        capture_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        jq -c --arg capturedAt "$capture_time" --argjson round "$round" \
            '{capturedAt:$capturedAt,round:$round,status:.}' "$status_file" \
            >> "$report_directory/filter-status-snapshots.jsonl" 2>/dev/null || true
    fi
    sleep 1
done

# Return to disabled mode immediately after either the observation period or a
# control-connectivity abort. Do not declare the machine safe just because the
# disable helper launched: preference persistence, DNS, and pre-resolved HTTPS
# must all recover. Reassert disable while checking for up to 30 seconds.
print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) cooperative_shutdown action=disable" >> "$report_directory/runner.log"
request_disable cooperative-shutdown "$control_outage_detected"
recovery_started_epoch="$(date +%s)"
recovery_deadline_epoch="$(( recovery_started_epoch + 30 ))"
while (( $(date +%s) <= recovery_deadline_epoch )); do
    recovery_attempt_count=$(( recovery_attempt_count + 1 ))
    if (( recovery_attempt_count > 1 && recovery_attempt_count % 3 == 1 )); then
        request_disable "recovery-reassert-$recovery_attempt_count" "$control_outage_detected"
    fi
    sleep 0.5
    if blocking_disable_is_persisted; then
        disable_persisted=1
    else
        disable_persisted=0
    fi
    if run_control_connectivity_probe recovery "$recovery_attempt_count"; then
        recovery_control_ok=1
    else
        recovery_control_ok=0
        if (( control_outage_detected == 0 )); then
            control_outage_detected=1
            control_outage_reason="post-disable-control-connectivity-lost"
            write_unsafe_latch "$control_outage_reason" \
                "A recovery probe failed after the runner requested emergency disable."
            request_disable "$control_outage_reason" 1
        fi
    fi
    print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) recovery_check attempt=$recovery_attempt_count disable_persisted=$disable_persisted dns_ok=$last_control_dns_ok https_ok=$last_control_https_ok" \
        >> "$report_directory/runner.log"
    if (( disable_persisted == 1 && recovery_control_ok == 1 )); then
        recovery_succeeded=1
        break
    fi
    sleep 0.5
done

if (( recovery_succeeded == 1 )); then
    post_result=0
    post_output="http=200,dns_ok=1,https_ok=1,disable_persisted=1,recovery_attempts=$recovery_attempt_count"
    /usr/bin/printf 'runner_recovered\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$completed_file"
    print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) recovery_complete attempts=$recovery_attempt_count watchdog=disarm" \
        >> "$report_directory/runner.log"
else
    post_result=75
    post_output="http=000,dns_ok=$last_control_dns_ok,https_ok=$last_control_https_ok,disable_persisted=$disable_persisted,recovery_attempts=$recovery_attempt_count"
    control_outage_detected=1
    [[ -n "$control_outage_reason" ]] || control_outage_reason="post-disable-recovery-deadline-exceeded"
    write_unsafe_latch "$control_outage_reason" \
        "DNS, pre-resolved HTTPS, and the persisted disable flag did not all recover within 30 seconds."
    request_disable "$control_outage_reason" 1
    print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) recovery_deadline_exceeded attempts=$recovery_attempt_count action=leave-watchdog-armed" \
        >> "$report_directory/runner.log"
fi
print -r -- "post_disable_connectivity\t$post_result\t${post_output//$'\n'/ }" >> "$report_directory/metadata.tsv"
print -r -- "disable_mode\tforced-command-line" >> "$report_directory/metadata.tsv"
print -r -- "recovery_succeeded\t$recovery_succeeded" >> "$report_directory/metadata.tsv"
print -r -- "recovery_attempt_count\t$recovery_attempt_count" >> "$report_directory/metadata.tsv"
print -r -- "control_outage_detected_final\t$control_outage_detected" >> "$report_directory/metadata.tsv"
print -r -- "control_outage_reason_final\t$control_outage_reason" >> "$report_directory/metadata.tsv"

scutil --nwi > "$report_directory/network-after.txt" 2>&1 || true
if [[ -r "$status_file" ]]; then cp "$status_file" "$report_directory/filter-status-after.json"; fi
/usr/bin/log show --start "$start_local" --style compact --info --debug \
    --predicate 'subsystem == "com.GabrielPrice.ExecutiveDysfunction" OR subsystem == "com.GabrielPrice.ExecutiveDysfunction.WebFilter"' \
    > "$report_directory/unified.log" 2>&1 || true
/usr/bin/log show --start "$start_local" --style compact --info --debug \
    --predicate 'process == "nesessionmanager" OR process == "neagent" OR process == "nehelper" OR process == "sysextd" OR process == "com.GabrielPrice.ExecutiveDysfunction.WebFilter"' \
    > "$report_directory/network-extension-system.log" 2>&1 || true

# Tie retry-guard evidence to the exact provider session accepted above. The
# settings log precedes provider_started and does not itself carry a session,
# so associate it with the next provider_started event from the same process.
# This prevents a positive correlation count from the replaced provider (or an
# earlier same-build restart) from satisfying this run.
ready_provider_evidence_file="$report_directory/ready-provider-evidence.tsv"
retry_guard_evidence_code=1
retry_guard_address_count="0"
retry_guard_coverage_exposed=0
retry_guard_coverage_matched=0
if [[ -n "$ready_provider_session" && -n "$ready_provider_build" ]]; then
    /usr/bin/awk \
        -v session="$ready_provider_session" \
        -v build="$ready_provider_build" \
        -v probeDomain="$coverage_probe_domain" \
        -v probeAddress="$blocked_probe_address" '
        function providerPID(line, token) {
            if (!match(line, /WebFilter\[[0-9]+:/)) return ""
            token = substr(line, RSTART, RLENGTH)
            sub(/^.*\[/, "", token)
            sub(/:$/, "", token)
            return token
        }
        {
            pid = providerPID($0)
            if (pid == "") next

            if (index($0, "provider_stopping session=") > 0) {
                if (targetFound && pid == targetPID) targetEnded = 1
                lastSettings[pid] = ""
                coverageSeen[pid] = 0
                coverageMatched[pid] = 0
                coverageLines[pid] = ""
                next
            }

            if (index($0, "provider_started session=") > 0) {
                if (index($0, "provider_started session=" session " ") > 0 &&
                    index($0, " build=" build " ") > 0) {
                    targetFound = 1
                    targetPID = pid
                    targetEnded = 0
                    targetSettings = lastSettings[pid]
                    targetCoverageSeen = coverageSeen[pid]
                    targetCoverageMatched = coverageMatched[pid]
                    print "provider_started\t" $0
                    if (targetSettings != "") print "filter_settings\t" targetSettings
                    if (coverageLines[pid] != "") {
                        printf "%s", coverageLines[pid]
                    }
                } else if (targetFound && pid == targetPID) {
                    targetEnded = 1
                }
                # Resolution/settings lines after one provider_started belong
                # to a later provider lifecycle, even when ExtensionKit reuses
                # the process for a same-build restart.
                lastSettings[pid] = ""
                coverageSeen[pid] = 0
                coverageMatched[pid] = 0
                coverageLines[pid] = ""
                next
            }

            if (index($0, "filter_settings_applied ") > 0) {
                if (targetFound && pid == targetPID && !targetEnded) {
                    targetSettings = $0
                    print "filter_settings\t" $0
                } else {
                    lastSettings[pid] = $0
                }
            }
            if (index($0, "correlated_") > 0 &&
                index($0, "domain=") > 0 &&
                index($0, "address=") > 0 &&
                index($0, "domain=<private>") == 0 &&
                index($0, "address=<private>") == 0) {
                isCoverageMatch = probeDomain != "" && probeAddress != "" &&
                    index($0, "domain=" probeDomain) > 0 &&
                    index($0, "address=" probeAddress) > 0
                if (targetFound && pid == targetPID && !targetEnded) {
                    targetCoverageSeen = 1
                    if (isCoverageMatch) targetCoverageMatched = 1
                    print "coverage\t" $0
                } else {
                    coverageSeen[pid] = 1
                    coverageLines[pid] = coverageLines[pid] "coverage\t" $0 "\n"
                    if (isCoverageMatch) coverageMatched[pid] = 1
                }
            }
        }
        END {
            if (!targetFound) exit 2
            print "coverage_exposed\t" (targetCoverageSeen ? 1 : 0)
            print "coverage_matched\t" (targetCoverageMatched ? 1 : 0)
            if (targetSettings !~ /correlated_addresses=[1-9][0-9]*/) exit 3
        }
    ' "$report_directory/unified.log" > "$ready_provider_evidence_file"
    retry_guard_evidence_code=$?
else
    print -r -- "error\tready provider identity unavailable" > "$ready_provider_evidence_file"
fi

if [[ -r "$ready_provider_evidence_file" ]]; then
    retry_guard_address_count="$(/usr/bin/sed -nE \
        '/^filter_settings[[:space:]]/s/.*correlated_addresses=([0-9]+).*/\1/p' \
        "$ready_provider_evidence_file" | /usr/bin/head -1)"
    [[ -n "$retry_guard_address_count" ]] || retry_guard_address_count="0"
    retry_guard_coverage_exposed="$(/usr/bin/awk -F '\t' \
        '$1 == "coverage_exposed" { print $2; exit }' \
        "$ready_provider_evidence_file")"
    retry_guard_coverage_matched="$(/usr/bin/awk -F '\t' \
        '$1 == "coverage_matched" { print $2; exit }' \
        "$ready_provider_evidence_file")"
    [[ -n "$retry_guard_coverage_exposed" ]] || retry_guard_coverage_exposed=0
    [[ -n "$retry_guard_coverage_matched" ]] || retry_guard_coverage_matched=0
fi
print -r -- "retry_guard_evidence_code\t$retry_guard_evidence_code" >> "$report_directory/metadata.tsv"
print -r -- "retry_guard_address_count\t$retry_guard_address_count" >> "$report_directory/metadata.tsv"
print -r -- "retry_guard_coverage_exposed\t$retry_guard_coverage_exposed" >> "$report_directory/metadata.tsv"
print -r -- "retry_guard_coverage_matched\t$retry_guard_coverage_matched" >> "$report_directory/metadata.tsv"

probe_count() {
    local name="$1" line count=0
    while IFS= read -r line; do
        [[ "$line" == *"\\t${name}\\t"* ]] && count=$(( count + 1 ))
    done < "$probes_file"
    print -r -- "$count"
}

probe_all_contain() {
    local name="$1" line expected found=0
    shift
    while IFS= read -r line; do
        if [[ "$line" == *"\\t${name}\\t"* ]]; then
            found=1
            for expected in "$@"; do
                [[ "$line" == *"$expected"* ]] || return 1
            done
        fi
    done < "$probes_file"
    (( found == 1 ))
}

probe_all_fail_before_http() {
    local name="$1" line found=0
    while IFS= read -r line; do
        if [[ "$line" == *"\\t${name}\\t"* ]]; then
            found=1
            [[ "$line" != *"\\t0\\t"* && "$line" == *"http=000"* ]] || return 1
        fi
    done < "$probes_file"
    (( found == 1 ))
}

probe_all_named_blocks_are_safe() {
    local line found=0
    while IFS= read -r line; do
        if [[ "$line" == *"\\thttps-policy-blocked\\t"* ]]; then
            found=1
            if [[ "$line" == *"\\t0\\t"* \
                && "$line" == *"http=403"* \
                && "$line" == *"block_page_message=1"* ]]; then
                continue
            fi
            if [[ "$line" != *"\\t0\\t"* && "$line" == *"http=000"* ]]; then
                continue
            fi
            return 1
        fi
    done < "$probes_file"
    (( found == 1 ))
}

summary_file="$report_directory/summary.txt"
summary_result="PASS"
print -r -- "Holdfast macOS filter smoke-test audit" > "$summary_file"
print -r -- "test_id=$test_id app_build=$deployed_build duration_seconds=$duration_seconds" >> "$summary_file"

record_summary_check() {
    local label="$1" succeeded="$2" detail="$3" check_status="PASS"
    if (( succeeded == 0 )); then
        check_status="FAIL"
        summary_result="FAIL"
    fi
    print -r -- "$check_status $label — $detail" >> "$summary_file"
}

record_summary_check filter_ready "$filter_ready" "new provider session=$ready_provider_session build=$ready_provider_build started_at_ms=$ready_provider_started_at"

if (( control_outage_detected == 0 )); then passed=1; else passed=0; fi
record_summary_check control_connectivity_guard "$passed" \
    "continuous DNS plus pre-resolved HTTPS guard; outage_detected=$control_outage_detected reason=$control_outage_reason"

record_summary_check retry_guard_status_coverage "$ready_retry_guard_coverage" "ready status proves the selected blocked suffix=$blocked_probe_domain was included in the applied retry-guard set"

if probe_all_contain https-example "\\t0\\t" "http=200"; then passed=1; else passed=0; fi
record_summary_check ordinary_https "$passed" "$(probe_count https-example) default-route rounds returned HTTP 200"

if probe_all_contain https-apple "\\t0\\t" "http=200"; then passed=1; else passed=0; fi
record_summary_check second_https_origin "$passed" "$(probe_count https-apple) Apple rounds returned HTTP 200"

if probe_all_contain https-example-utun9 "\\t0\\t" "http=200"; then passed=1; else passed=0; fi
record_summary_check vpn_tunnel_https "$passed" "$(probe_count https-example-utun9) utun9 rounds returned HTTP 200"

if probe_all_contain dns-example "\\t0\\t"; then passed=1; else passed=0; fi
record_summary_check ordinary_dns "$passed" "$(probe_count dns-example) DNS rounds succeeded"

if probe_all_contain tcp-allowed-apple-443 "\\t0\\t"; then passed=1; else passed=0; fi
record_summary_check allowed_raw_tcp "$passed" "$(probe_count tcp-allowed-apple-443) pre-resolved Apple TCP rounds connected"

if probe_all_named_blocks_are_safe; then passed=1; else passed=0; fi
record_summary_check named_block "$passed" "$(probe_count https-policy-blocked) policy-domain rounds showed the verified page or failed before HTTP"

if probe_all_fail_before_http https-policy-blocked-resolved; then passed=1; else passed=0; fi
record_summary_check cached_ip_retry_block "$passed" "$(probe_count https-policy-blocked-resolved) cached-IP rounds failed before HTTP"

if (( retry_guard_evidence_code == 0 )); then passed=1; else passed=0; fi
record_summary_check retry_guard_rules "$passed" "ready session=$ready_provider_session build=$ready_provider_build installed $retry_guard_address_count public cached-IP address guard(s); evidence_code=$retry_guard_evidence_code"

if (( retry_guard_coverage_exposed == 1 )); then
    if (( retry_guard_coverage_matched == 1 )); then passed=1; else passed=0; fi
    coverage_detail="provider coverage logs exposed; selected domain=$coverage_probe_domain address=$blocked_probe_address matched=$retry_guard_coverage_matched"
else
    passed=1
    coverage_detail="provider logs did not expose per-domain/address coverage; cached-IP transport probe remains authoritative"
fi
record_summary_check retry_guard_probe_coverage "$passed" "$coverage_detail"

if [[ -n "$ready_provider_session" \
    && -r "$report_directory/filter-status-after.json" ]] && jq -e \
    --arg build "$deployed_build" \
    --arg session "$ready_provider_session" \
    '.diagnostics.providerBuild == $build
        and .diagnostics.sessionID == $session
        and .diagnostics.failOpenActive == false
        and .diagnostics.failOpenTrips == 0
        and .diagnostics.unidentifiedDropsInWindow == 0' \
    "$report_directory/filter-status-after.json" >/dev/null 2>&1; then
    passed=1
else
    passed=0
fi
record_summary_check provider_safety "$passed" "ready build/session persisted through disable; fail-open inactive; zero unidentified drops"

if (( post_result == 0 )) && [[ "$post_output" == *"http=200"* ]]; then passed=1; else passed=0; fi
record_summary_check post_disable_connectivity "$passed" "exit=$post_result $post_output"

if (( recovery_succeeded == 1 )); then passed=1; else passed=0; fi
record_summary_check bounded_recovery "$passed" \
    "disable persistence plus DNS and pre-resolved HTTPS recovered=$recovery_succeeded attempts=$recovery_attempt_count"

if [[ -e "$unsafe_latch_file" ]]; then
    print -r -- "SAFETY LATCH $unsafe_latch_file" >> "$summary_file"
    print -r -- "REQUIRED Keep filtering disabled; use the safe in-app enforcement reset, or restart this Mac if reset cannot prove recovery, before another live smoke test." >> "$summary_file"
fi

print -r -- "OVERALL $summary_result" >> "$summary_file"

if (( recovery_succeeded == 1 )); then
    normal_completion=1
fi
print -r -- "Smoke test complete. Report: $report_directory"
print -r -- "Post-disable connectivity: exit=$post_result $post_output"
print -r -- "Audit result: $summary_result ($summary_file)"
if [[ -e "$unsafe_latch_file" ]]; then
    print -r -- "Unsafe/reboot-required latch: $unsafe_latch_file"
fi
if (( recovery_succeeded == 0 )); then
    exit 75
fi
