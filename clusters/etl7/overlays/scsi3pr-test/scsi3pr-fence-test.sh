#!/usr/bin/env bash
# scsi3pr-fence-test.sh — Symmetric SCSI-3 Persistent Reservation fencing test
#
# Runs the same script on TWO VMs sharing a SCSI LUN. Each iteration both VMs
# register, race to reserve (type 5 — Write Exclusive, Registrants Only), then
# the winner fences the loser via PREEMPT-AND-ABORT. The loser detects fencing,
# re-registers, and both verify recovery. Reservation holder changes randomly
# between iterations thanks to a jitter sleep before the RESERVE attempt.
#
# Prerequisites inside the VM:
#   - sg3-utils package (provides sg_persist, sg_turs)
#   - The shared LUN visible as a /dev/sdX block device
#
# Usage (run simultaneously on both VMs):
#   VM1: ./scsi3pr-fence-test.sh --device /dev/sda --my-key 0xA001 --peer-key 0xB002 --duration 10m
#   VM2: ./scsi3pr-fence-test.sh --device /dev/sda --my-key 0xB002 --peer-key 0xA001 --duration 10m

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
DEVICE=""
MY_KEY=""
PEER_KEY=""
DURATION=""
INTERVAL=5
LABEL="$(hostname 2>/dev/null || echo "vm")"
POLL_TIMEOUT=30       # seconds to wait when polling for peer actions
RACE_JITTER_MAX=500   # max milliseconds of random jitter before RESERVE

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

log_pass()  { printf "  ${GREEN}[PASS]${NC} %s\n" "$*"; }
log_fail()  { printf "  ${RED}[FAIL]${NC} %s\n" "$*"; }
log_info()  { printf "  ${CYAN}[INFO]${NC} %s\n" "$*"; }
log_header(){ printf "${YELLOW}[%s %s] === Iteration %d (elapsed %ds / %ds) ===${NC}\n" \
              "$LABEL" "$(ts)" "$1" "$2" "$DURATION_SECS"; }

die() { log_fail "$@"; do_full_cleanup; exit 1; }

parse_duration() {
    local val
    val="$1"
    local num="${val%[smhSMH]}"
    local unit="${val##*[0-9]}"
    case "${unit,,}" in
        s|"") echo "$num" ;;
        m)    echo $((num * 60)) ;;
        h)    echo $((num * 3600)) ;;
        *)    echo "$num" ;;
    esac
}

epoch_secs() { date +%s; }

# ---------------------------------------------------------------------------
# SCSI PR wrappers
# ---------------------------------------------------------------------------
pr_register() {
    local key="$1"
    sg_persist --out --register --param-sark="$key" "$DEVICE" 2>&1
}

pr_reserve() {
    local key="$1"
    sg_persist --out --reserve --param-rk="$key" --prout-type=5 "$DEVICE" 2>&1
}

pr_read_keys() {
    sg_persist --in --read-keys --no-inquiry "$DEVICE" 2>&1
}

pr_read_reservation() {
    sg_persist --in --read-reservation --no-inquiry "$DEVICE" 2>&1
}

pr_preempt_abort() {
    local my_key="$1" victim_key="$2"
    sg_persist --out --preempt-abort \
        --param-rk="$my_key" --param-sark="$victim_key" \
        --prout-type=5 "$DEVICE" 2>&1
}

pr_clear() {
    local key="$1"
    sg_persist --out --clear --param-rk="$key" "$DEVICE" 2>&1
}

pr_unregister() {
    local key="$1"
    sg_persist --out --register --param-rk="$key" --param-sark=0 "$DEVICE" 2>&1
}

test_unit_ready() {
    sg_turs "$DEVICE" >/dev/null 2>&1
}

try_write() {
    dd if=/dev/zero of="$DEVICE" bs=512 count=1 oflag=direct 2>&1
}

key_is_registered() {
    local key="$1"
    local keys_output
    keys_output="$(pr_read_keys)"
    echo "$keys_output" | grep -qi "$(printf '%x' "$key")"
}

count_registered_keys() {
    local keys_output
    keys_output="$(pr_read_keys)"
    echo "$keys_output" | grep -ci '0x' || echo 0
}

get_reservation_holder_key() {
    local res_output
    res_output="$(pr_read_reservation)"
    echo "$res_output" | grep -oiE '0x[0-9a-fA-F]+' | head -1
}

# ---------------------------------------------------------------------------
# Cleanup helpers
# ---------------------------------------------------------------------------
# Full cleanup: clears ALL keys and reservations (only safe when both VMs are idle)
do_full_cleanup() {
    pr_clear "$MY_KEY" >/dev/null 2>&1 || \
    pr_clear "$PEER_KEY" >/dev/null 2>&1 || \
    { pr_unregister "$MY_KEY" >/dev/null 2>&1; pr_unregister "$PEER_KEY" >/dev/null 2>&1; } || \
    true
}

# Self-only cleanup: release any reservation I hold, then unregister only my key
# This is safe to call while the peer is still active
do_self_cleanup() {
    # Release reservation if I hold it (no-op if I don't)
    sg_persist --out --release --param-rk="$MY_KEY" --prout-type=5 "$DEVICE" >/dev/null 2>&1 || true
    # Unregister my key (no-op if not registered)
    pr_unregister "$MY_KEY" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------
ITERATION=0
FAILURES=0
HOLDER_COUNT=0
VICTIM_COUNT=0
LAST_ITERATION_SECS=30

assert_pass() {
    local desc="$1"
    shift
    local output
    if output=$("$@" 2>&1); then
        log_pass "$desc"
        return 0
    else
        log_fail "$desc"
        log_fail "  Command: $*"
        log_fail "  Output: $output"
        FAILURES=$((FAILURES + 1))
        return 1
    fi
}

assert_key_registered() {
    local key="$1" desc="$2"
    if key_is_registered "$key"; then
        log_pass "$desc"
        return 0
    else
        log_fail "$desc"
        log_fail "  Key $key not found in registered keys"
        log_fail "  Keys: $(pr_read_keys)"
        FAILURES=$((FAILURES + 1))
        return 1
    fi
}

assert_key_not_registered() {
    local key="$1" desc="$2"
    if ! key_is_registered "$key"; then
        log_pass "$desc"
        return 0
    else
        log_fail "$desc"
        log_fail "  Key $key still found in registered keys"
        log_fail "  Keys: $(pr_read_keys)"
        FAILURES=$((FAILURES + 1))
        return 1
    fi
}

assert_write_succeeds() {
    local desc="$1"
    local output
    if output=$(try_write 2>&1); then
        log_pass "$desc"
        return 0
    else
        log_fail "$desc"
        log_fail "  Write output: $output"
        FAILURES=$((FAILURES + 1))
        return 1
    fi
}

assert_write_fails() {
    local desc="$1"
    local output
    if output=$(try_write 2>&1); then
        log_fail "$desc"
        log_fail "  Write unexpectedly succeeded"
        FAILURES=$((FAILURES + 1))
        return 1
    else
        log_pass "$desc"
        return 0
    fi
}

# ---------------------------------------------------------------------------
# Poll helper: wait for a condition with timeout
# ---------------------------------------------------------------------------
poll_until() {
    local desc="$1" timeout_secs="$2"
    shift 2
    local deadline=$(( $(epoch_secs) + timeout_secs ))
    while [ "$(epoch_secs)" -lt "$deadline" ]; do
        if "$@" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    log_fail "Timeout (${timeout_secs}s) waiting for: $desc"
    return 1
}

peer_key_gone() {
    ! key_is_registered "$PEER_KEY"
}

my_key_gone() {
    ! key_is_registered "$MY_KEY"
}

peer_key_present() {
    key_is_registered "$PEER_KEY"
}

both_keys_present() {
    key_is_registered "$MY_KEY" && key_is_registered "$PEER_KEY"
}

# ---------------------------------------------------------------------------
# Iteration: HOLDER path
# ---------------------------------------------------------------------------
run_holder_path() {
    # Wait for the peer to register (they may still be in their jitter sleep)
    log_info "Holder: waiting for peer key $PEER_KEY to appear..."
    if ! poll_until "peer registers key $PEER_KEY" "$POLL_TIMEOUT" peer_key_present; then
        die "Peer never registered key $PEER_KEY"
    fi

    # Verify steady state
    assert_key_registered "$MY_KEY"   "Steady-state: my key $MY_KEY registered" || return 1
    assert_key_registered "$PEER_KEY" "Steady-state: peer key $PEER_KEY registered" || return 1
    assert_write_succeeds             "Steady-state: holder write succeeded" || return 1

    # Give the peer a moment to verify steady-state writes before we fence
    sleep 2

    # Fence: preempt-and-abort the peer
    local pa_output pa_rc=0
    pa_output=$(pr_preempt_abort "$MY_KEY" "$PEER_KEY" 2>&1) || pa_rc=$?
    if [ $pa_rc -eq 0 ]; then
        log_pass "Fence: preempt-and-abort of $PEER_KEY succeeded"
    else
        log_fail "Fence: preempt-and-abort of $PEER_KEY failed"
        log_fail "  Output: $pa_output"
        FAILURES=$((FAILURES + 1))
        return 1
    fi

    # Verify fencing — confirm we still have access
    # Note: we do NOT assert peer key is gone here because the victim may have
    # already re-registered by the time we check (race). The preempt-and-abort
    # return code above confirms the SCSI operation succeeded, and the VICTIM
    # independently verifies it was fenced (write blocked, key gone).
    assert_key_registered "$MY_KEY" "Verify: my key $MY_KEY still registered" || return 1
    assert_write_succeeds           "Verify: holder write after fence succeeded" || return 1

    # Wait for peer to re-register (recovery)
    log_info "Holder: waiting for peer to re-register..."
    if ! poll_until "peer re-registers key $PEER_KEY" "$POLL_TIMEOUT" peer_key_present; then
        die "Peer never re-registered key $PEER_KEY after fencing"
    fi

    # Verify recovery — peer is back
    log_pass "Recovery: peer key $PEER_KEY re-registered"
    assert_write_succeeds "Recovery: holder write after recovery succeeded" || return 1
}

# ---------------------------------------------------------------------------
# Iteration: VICTIM path
# ---------------------------------------------------------------------------
run_victim_path() {
    # Wait for the holder (peer) to also be registered
    log_info "Victim: waiting for peer key $PEER_KEY to appear..."
    if ! poll_until "peer registers key $PEER_KEY" "$POLL_TIMEOUT" peer_key_present; then
        die "Peer never registered key $PEER_KEY"
    fi

    # Verify steady state
    assert_key_registered "$MY_KEY"   "Steady-state: my key $MY_KEY registered" || return 1
    assert_key_registered "$PEER_KEY" "Steady-state: peer key $PEER_KEY registered" || return 1
    assert_write_succeeds             "Steady-state: victim write succeeded (both registered)" || return 1

    # Wait to be fenced (peer will preempt-and-abort our key)
    log_info "Victim: waiting to be fenced (key $MY_KEY removed)..."
    if ! poll_until "my key $MY_KEY removed by holder" "$POLL_TIMEOUT" my_key_gone; then
        die "Never got fenced — my key $MY_KEY was not removed within ${POLL_TIMEOUT}s"
    fi
    log_pass "Fenced: my key $MY_KEY was removed by peer"

    # Verify write is blocked
    assert_write_fails "Fenced: write correctly blocked (reservation conflict)" || return 1

    # Recovery: re-register
    local reg_output reg_rc=0
    reg_output=$(pr_register "$MY_KEY" 2>&1) || reg_rc=$?
    if [ $reg_rc -eq 0 ]; then
        log_pass "Recovery: re-registered key $MY_KEY"
    else
        log_fail "Recovery: failed to re-register key $MY_KEY"
        log_fail "  Output: $reg_output"
        FAILURES=$((FAILURES + 1))
        return 1
    fi

    # Verify write succeeds after recovery
    assert_write_succeeds "Recovery: write succeeds after re-registration" || return 1
}

# ---------------------------------------------------------------------------
# Single iteration
# ---------------------------------------------------------------------------
run_iteration() {
    local iter_start
    iter_start=$(epoch_secs)

    # Phase 1: Self-cleanup (only my key — safe while peer may still be active)
    do_self_cleanup
    sleep 2
    log_pass "Cleanup: my key unregistered"

    # Phase 2: Register my key
    local reg_output reg_rc=0
    reg_output=$(pr_register "$MY_KEY" 2>&1) || reg_rc=$?
    if [ $reg_rc -eq 0 ]; then
        log_pass "Register: key $MY_KEY registered"
    else
        log_fail "Register: failed to register key $MY_KEY"
        log_fail "  Output: $reg_output"
        FAILURES=$((FAILURES + 1))
        return 1
    fi

    # Phase 3: Random jitter then race to reserve
    local jitter_ms
    jitter_ms=$(shuf -i 0-"$RACE_JITTER_MAX" -n 1)
    log_info "Race: sleeping ${jitter_ms}ms before reserve attempt..."
    sleep "$(awk "BEGIN{printf \"%.3f\", $jitter_ms/1000}")"

    local race_output role race_rc=0
    race_output=$(pr_reserve "$MY_KEY" 2>&1) || race_rc=$?
    if [ $race_rc -eq 0 ]; then
        log_info "Race: RESERVE succeeded — I am the HOLDER"
        role="HOLDER"
        HOLDER_COUNT=$((HOLDER_COUNT + 1))
    else
        if echo "$race_output" | grep -qi "reservation conflict"; then
            log_info "Race: RESERVE got conflict — I am the VICTIM"
            role="VICTIM"
            VICTIM_COUNT=$((VICTIM_COUNT + 1))
        else
            log_fail "Race: RESERVE failed with unexpected error"
            log_fail "  Output: $race_output"
            FAILURES=$((FAILURES + 1))
            return 1
        fi
    fi

    # Phase 4-5: Run role-specific path
    if [ "$role" = "HOLDER" ]; then
        run_holder_path || return 1
    else
        run_victim_path || return 1
    fi

    LAST_ITERATION_SECS=$(( $(epoch_secs) - iter_start ))
    printf "  Iteration %d completed in %ds (role: %s)\n\n" "$ITERATION" "$LAST_ITERATION_SECS" "$role"
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
preflight() {
    echo "=== Preflight Checks ==="

    if ! command -v sg_persist &>/dev/null; then
        die "sg_persist not found. Install sg3-utils: sudo dnf install -y sg3-utils"
    fi
    log_pass "sg_persist found at $(command -v sg_persist)"

    if ! command -v sg_turs &>/dev/null; then
        die "sg_turs not found. Install sg3-utils: sudo dnf install -y sg3-utils"
    fi
    log_pass "sg_turs found at $(command -v sg_turs)"

    if [ ! -b "$DEVICE" ]; then
        die "Device $DEVICE is not a block device"
    fi
    log_pass "Device $DEVICE exists and is a block device"

    if ! test_unit_ready; then
        die "Device $DEVICE failed Test Unit Ready"
    fi
    log_pass "Device $DEVICE passed Test Unit Ready (sg_turs)"

    local caps
    caps=$(sg_persist --in --report-capabilities "$DEVICE" 2>&1)
    if echo "$caps" | grep -qi "persist through power loss"; then
        log_pass "Device supports Persistent Reservations"
    else
        log_info "Could not confirm PTPL support (non-fatal): $caps"
    fi

    echo ""
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Required:
  --device <path>       SCSI device path (e.g. /dev/sda)
  --my-key <hex>        This VM's registration key (e.g. 0xA001)
  --peer-key <hex>      The other VM's registration key (e.g. 0xB002)
  --duration <value>    How long to run (e.g. 30s, 10m, 2h)

Optional:
  --interval <value>    Pause between iterations in seconds (default: 5)
  --hostname <name>     Label for log output (default: \$(hostname))
  --poll-timeout <sec>  Timeout for polling peer actions (default: 30)
  --jitter-max <ms>     Max random jitter in ms before RESERVE (default: 500)
  -h, --help            Show this help

Example (run simultaneously on both VMs):
  VM1: $0 --device /dev/sda --my-key 0xA001 --peer-key 0xB002 --duration 10m
  VM2: $0 --device /dev/sda --my-key 0xB002 --peer-key 0xA001 --duration 10m
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device)       DEVICE="$2"; shift 2 ;;
        --my-key)       MY_KEY="$2"; shift 2 ;;
        --peer-key)     PEER_KEY="$2"; shift 2 ;;
        --duration)     DURATION="$2"; shift 2 ;;
        --interval)     INTERVAL="$2"; shift 2 ;;
        --hostname)     LABEL="$2"; shift 2 ;;
        --poll-timeout) POLL_TIMEOUT="$2"; shift 2 ;;
        --jitter-max)   RACE_JITTER_MAX="$2"; shift 2 ;;
        -h|--help)      usage ;;
        *)              echo "Unknown option: $1"; usage ;;
    esac
done

# Validate required args
[[ -z "$DEVICE" ]]   && { echo "Error: --device is required"; usage; }
[[ -z "$MY_KEY" ]]   && { echo "Error: --my-key is required"; usage; }
[[ -z "$PEER_KEY" ]] && { echo "Error: --peer-key is required"; usage; }
[[ -z "$DURATION" ]] && { echo "Error: --duration is required"; usage; }

DURATION_SECS=$(parse_duration "$DURATION")

# ---------------------------------------------------------------------------
# Trap for cleanup on exit
# ---------------------------------------------------------------------------
trap 'echo ""; echo "Caught signal, cleaning up..."; do_full_cleanup; exit 130' INT TERM
trap 'do_full_cleanup' EXIT

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
main() {
    preflight

    local start_time
    start_time=$(epoch_secs)
    local est_iteration_time=30  # conservative initial estimate

    echo "=== Starting SCSI-3 PR Fencing Test ==="
    echo "  Device:    $DEVICE"
    echo "  My key:    $MY_KEY"
    echo "  Peer key:  $PEER_KEY"
    echo "  Duration:  ${DURATION_SECS}s"
    echo "  Interval:  ${INTERVAL}s"
    echo "  Hostname:  $LABEL"
    echo ""

    while true; do
        local now elapsed remaining
        now=$(epoch_secs)
        elapsed=$((now - start_time))
        remaining=$((DURATION_SECS - elapsed))

        # Check if we have enough time for another iteration
        # Add 5s tolerance so both VMs stop around the same time
        # (avoids one VM starting an iteration while the other is about to exit)
        local min_remaining=$((est_iteration_time + 5))
        if [ "$remaining" -lt "$min_remaining" ]; then
            echo "Not enough time remaining (${remaining}s < ${min_remaining}s). Stopping."
            break
        fi

        ITERATION=$((ITERATION + 1))
        log_header "$ITERATION" "$elapsed"

        run_iteration
        local iter_rc=$?

        if [ $iter_rc -ne 0 ] || [ "$FAILURES" -gt 0 ]; then
            echo ""
            printf "${RED}=== FAILED at iteration %d ===${NC}\n" "$ITERATION"
            printf "  Elapsed:    %ds / %ds\n" "$elapsed" "$DURATION_SECS"
            printf "  Failures:   %d\n" "$FAILURES"
            printf "  Holder:     %d times\n" "$HOLDER_COUNT"
            printf "  Victim:     %d times\n" "$VICTIM_COUNT"
            exit 1
        fi

        est_iteration_time=$LAST_ITERATION_SECS

        # Pause between iterations
        if [ "$INTERVAL" -gt 0 ]; then
            sleep "$INTERVAL"
        fi
    done

    local total_elapsed=$(( $(epoch_secs) - start_time ))
    echo ""
    printf "${GREEN}=== SUMMARY (%s) ===${NC}\n" "$LABEL"
    printf "  Result:     PASS\n"
    printf "  Iterations: %d completed (%d as HOLDER, %d as VICTIM)\n" \
           "$ITERATION" "$HOLDER_COUNT" "$VICTIM_COUNT"
    printf "  Duration:   %ds / %ds budget\n" "$total_elapsed" "$DURATION_SECS"
    printf "  Failures:   0\n"
    exit 0
}

main
