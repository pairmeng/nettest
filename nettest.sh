#!/usr/bin/env bash

# ==================================================
# Global Network Quality Test Script
# GitHub Version
# ==================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_DIR="${LOG_DIR:-./logs}"
readonly TIMESTAMP="$(date +"%Y%m%d_%H%M%S")"
readonly SERVER_PID_FILE="$LOG_DIR/server.pid"

readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

readonly PING_COUNT="${PING_COUNT:-20}"
readonly MTR_COUNT="${MTR_COUNT:-100}"
readonly TCP_STREAMS="${TCP_STREAMS:-8}"
readonly UDP_BANDWIDTH="${UDP_BANDWIDTH:-100M}"
readonly HTTP_BYTES="${HTTP_BYTES:-100000000}"
readonly HTTP_TEST_URL="${HTTP_TEST_URL:-https://speed.cloudflare.com/__down?bytes=${HTTP_BYTES}}"
readonly LOOP_SLEEP_SECONDS="${LOOP_SLEEP_SECONDS:-1800}"
IPERF_SERVER="${IPERF_SERVER:-}"
IPERF_PORT="${IPERF_PORT:-5201}"

MODE="${1:-}"
TARGET="${2:-}"

mkdir -p "$LOG_DIR"

print_info() {
    echo -e "${GREEN}[+]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[-]${NC} $1"
}

usage() {
    cat <<EOF
==================================
 Global Network Test Script
==================================

Usage:
  ./$SCRIPT_NAME server
  ./$SCRIPT_NAME client <IP>
  ./$SCRIPT_NAME loop <IP>

Optional overrides:
  LOG_DIR=./logs
  PING_COUNT=20
  MTR_COUNT=100
  TCP_STREAMS=8
  UDP_BANDWIDTH=100M
  HTTP_BYTES=100000000
  LOOP_SLEEP_SECONDS=1800
  HTTP_TEST_URL=https://...
  IPERF_SERVER=<host>
  IPERF_PORT=5201
EOF
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

require_target() {
    if [[ -z "${TARGET}" ]]; then
        print_error "Target IP or hostname required"
        usage
        exit 1
    fi
}

run_as_root() {
    if [[ "${EUID}" -eq 0 ]]; then
        "$@"
    elif have_cmd sudo; then
        sudo "$@"
    else
        print_error "Root or sudo is required to install missing dependencies"
        exit 1
    fi
}

SKIPPED_TESTS=()
FAILED_TESTS=()
PASSED_TESTS=()

install_deps() {
    local missing=()
    local pkg_mgr=""
    local deps=("$@")

    print_info "Checking dependencies..."

    for dep in "${deps[@]}"; do
        if ! have_cmd "$dep"; then
            missing+=("$dep")
        fi
    done

    if ((${#missing[@]} == 0)); then
        print_info "All dependencies are available"
        return 0
    fi

    print_warn "Missing dependencies: ${missing[*]}"

    if have_cmd apt-get; then
        pkg_mgr="apt-get"
        export DEBIAN_FRONTEND=noninteractive
        run_as_root apt-get update
        run_as_root apt-get install -y "${missing[@]}"
    elif have_cmd dnf; then
        pkg_mgr="dnf"
        run_as_root dnf install -y epel-release || true
        run_as_root dnf install -y "${missing[@]}"
    elif have_cmd yum; then
        pkg_mgr="yum"
        run_as_root yum install -y epel-release || true
        run_as_root yum install -y "${missing[@]}"
    elif have_cmd apk; then
        pkg_mgr="apk"
        run_as_root apk add --no-cache "${missing[@]}"
    else
        print_error "Unsupported package manager"
        exit 1
    fi

    print_info "Dependencies installed via ${pkg_mgr}"
}

install_mode_deps() {
    case "$1" in
        server)
            install_deps iperf3
            ;;
        client|loop)
            install_deps iperf3 mtr traceroute curl bc
            ;;
        *)
            return 0
            ;;
    esac
}

run_test() {
    local title="$1"
    local log_file="$2"
    shift 2

    print_info "$title"

    if "$@" 2>&1 | tee "$log_file"; then
        PASSED_TESTS+=("$title")
        return 0
    fi

    local status=${PIPESTATUS[0]}
    FAILED_TESTS+=("$title")
    print_warn "$title failed with exit code $status (continuing)"
    return 0
}

skip_test() {
    local title="$1"
    local reason="$2"

    SKIPPED_TESTS+=("$title")
    print_warn "$title skipped: $reason"
}

port_is_open() {
    local host="$1"
    local port="$2"

    if have_cmd timeout; then
        timeout 3 bash -c ':</dev/tcp/"$1"/"$2"' _ "$host" "$port" >/dev/null 2>&1
    else
        bash -c ':</dev/tcp/"$1"/"$2"' _ "$host" "$port" >/dev/null 2>&1
    fi
}

server_mode() {
    local pid=""

    if [[ -f "$SERVER_PID_FILE" ]]; then
        pid="$(<"$SERVER_PID_FILE")"
        if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
            print_warn "iperf3 server already running (PID $pid)"
            print_info "Listening on TCP/5201"
            return 0
        fi
    fi

    print_info "Starting iperf3 server..."

    nohup iperf3 -s > "$LOG_DIR/server.log" 2>&1 &
    pid=$!
    echo "$pid" > "$SERVER_PID_FILE"

    print_info "iperf3 server started (PID $pid)"
    print_info "Listening on TCP/5201"
}

ping_test() {
    local run_ts="$1"

    run_test \
        "Running Ping Test..." \
        "$LOG_DIR/ping_${run_ts}.log" \
        ping -c "$PING_COUNT" "$TARGET"
}

trace_test() {
    local run_ts="$1"

    run_test \
        "Running Traceroute..." \
        "$LOG_DIR/traceroute_${run_ts}.log" \
        traceroute "$TARGET"
}

mtr_test() {
    local run_ts="$1"

    run_test \
        "Running MTR Test..." \
        "$LOG_DIR/mtr_${run_ts}.log" \
        mtr -rwzbc "$MTR_COUNT" "$TARGET"
}

tcp_test() {
    local run_ts="$1"

    if ! port_is_open "$IPERF_SERVER" "$IPERF_PORT"; then
        skip_test \
            "Running TCP Bandwidth Test..." \
            "iperf3 server not reachable at ${IPERF_SERVER}:${IPERF_PORT}"
        return 0
    fi

    run_test \
        "Running TCP Bandwidth Test..." \
        "$LOG_DIR/tcp_${run_ts}.log" \
        iperf3 -c "$IPERF_SERVER" -p "$IPERF_PORT" -P "$TCP_STREAMS"
}

udp_test() {
    local run_ts="$1"

    if ! port_is_open "$IPERF_SERVER" "$IPERF_PORT"; then
        skip_test \
            "Running UDP Quality Test..." \
            "iperf3 server not reachable at ${IPERF_SERVER}:${IPERF_PORT}"
        return 0
    fi

    run_test \
        "Running UDP Quality Test..." \
        "$LOG_DIR/udp_${run_ts}.log" \
        iperf3 -c "$IPERF_SERVER" -p "$IPERF_PORT" -u -b "$UDP_BANDWIDTH"
}

http_test() {
    local run_ts="$1"

    run_test \
        "Running Real HTTP Download Test..." \
        "$LOG_DIR/http_${run_ts}.log" \
        curl --silent --show-error --location \
            --output /dev/null \
            --write-out $'\nDownload Speed: %{speed_download} bytes/s\n' \
            "$HTTP_TEST_URL"
}

client_mode() {
    local run_ts

    require_target

    if [[ -z "$IPERF_SERVER" ]]; then
        IPERF_SERVER="$TARGET"
    fi

    run_ts="$(date +"%Y%m%d_%H%M%S")"

    print_info "Target: $TARGET"
    print_info "Start Time: $(date)"
    echo

    ping_test "$run_ts"
    echo

    trace_test "$run_ts"
    echo

    mtr_test "$run_ts"
    echo

    tcp_test "$run_ts"
    echo

    udp_test "$run_ts"
    echo

    http_test "$run_ts"
    echo

    print_info "All tests completed"
    print_info "Logs saved in: $LOG_DIR"
}

print_summary() {
    echo
    print_info "Summary"
    print_info "Passed: ${#PASSED_TESTS[@]}"
    print_warn "Failed: ${#FAILED_TESTS[@]}"
    print_warn "Skipped: ${#SKIPPED_TESTS[@]}"

    if ((${#FAILED_TESTS[@]} > 0)); then
        print_warn "Failed tests: ${FAILED_TESTS[*]}"
    fi

    if ((${#SKIPPED_TESTS[@]} > 0)); then
        print_warn "Skipped tests: ${SKIPPED_TESTS[*]}"
    fi
}

loop_mode() {
    require_target

    while true; do
        print_warn "Loop test started: $(date)"

        client_mode

        print_warn "Sleeping ${LOOP_SLEEP_SECONDS} seconds..."
        sleep "$LOOP_SLEEP_SECONDS"
    done
}

case "$MODE" in
    server)
        # Server mode only needs iperf3.
        install_mode_deps server
        server_mode
        ;;
    client)
        install_mode_deps client
        client_mode
        ;;
    loop)
        install_mode_deps loop
        loop_mode
        ;;
    *)
        usage
        exit 1
        ;;
esac

print_summary
