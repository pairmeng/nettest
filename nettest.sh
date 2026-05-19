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
readonly SERVER_PID_FILE="$LOG_DIR/server_${IPERF_PORT}.pid"
readonly SERVER_LOG_FILE="$LOG_DIR/server_${IPERF_PORT}.log"
REPORT_FILE=""

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
  ./$SCRIPT_NAME <IP>

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

package_for_dep() {
    local pkg_mgr="$1"
    local dep="$2"

    case "$dep" in
        ping)
            case "$pkg_mgr" in
                apt-get) printf '%s' "iputils-ping" ;;
                dnf|yum|apk) printf '%s' "iputils" ;;
                *) printf '%s' "$dep" ;;
            esac
            ;;
        *)
            printf '%s' "$dep"
            ;;
    esac
}

require_target() {
    if [[ -z "${TARGET}" ]]; then
        print_error "Target IP or hostname required"
        usage
        exit 1
    fi
}

normalize_args() {
    case "$MODE" in
        server|client|loop)
            ;;
        -h|--help|help)
            usage
            exit 0
            ;;
        "")
            usage
            exit 1
            ;;
        *)
            if [[ -z "$TARGET" ]]; then
                TARGET="$MODE"
                MODE="client"
            else
                print_error "Unknown mode: $MODE"
                usage
                exit 1
            fi
            ;;
    esac
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
RESULT_TITLES=()
RESULT_STATUSES=()
RESULT_SUMMARIES=()
RESULT_LOG_FILES=()
RESULT_NOTES=()

install_deps() {
    local missing=()
    local pkg_mgr=""
    local packages=()
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
        packages=()
        for dep in "${missing[@]}"; do
            packages+=("$(package_for_dep "$pkg_mgr" "$dep")")
        done
        run_as_root apt-get update
        run_as_root apt-get install -y "${packages[@]}"
    elif have_cmd dnf; then
        pkg_mgr="dnf"
        packages=()
        for dep in "${missing[@]}"; do
            packages+=("$(package_for_dep "$pkg_mgr" "$dep")")
        done
        run_as_root dnf install -y epel-release || true
        run_as_root dnf install -y "${packages[@]}"
    elif have_cmd yum; then
        pkg_mgr="yum"
        packages=()
        for dep in "${missing[@]}"; do
            packages+=("$(package_for_dep "$pkg_mgr" "$dep")")
        done
        run_as_root yum install -y epel-release || true
        run_as_root yum install -y "${packages[@]}"
    elif have_cmd apk; then
        pkg_mgr="apk"
        packages=()
        for dep in "${missing[@]}"; do
            packages+=("$(package_for_dep "$pkg_mgr" "$dep")")
        done
        run_as_root apk add --no-cache "${packages[@]}"
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
            install_deps iperf3 mtr traceroute curl bc ping
            ;;
        *)
            return 0
            ;;
    esac
}

reset_run_state() {
    SKIPPED_TESTS=()
    FAILED_TESTS=()
    PASSED_TESTS=()
    RESULT_TITLES=()
    RESULT_STATUSES=()
    RESULT_SUMMARIES=()
    RESULT_LOG_FILES=()
    RESULT_NOTES=()
    REPORT_FILE=""
}

append_result() {
    local title="$1"
    local status="$2"
    local summary="$3"
    local log_file="$4"
    local note="${5:-}"

    RESULT_TITLES+=("$title")
    RESULT_STATUSES+=("$status")
    RESULT_SUMMARIES+=("$summary")
    RESULT_LOG_FILES+=("$log_file")
    RESULT_NOTES+=("$note")
}

html_escape() {
    local text="$1"

    text="${text//&/&amp;}"
    text="${text//</&lt;}"
    text="${text//>/&gt;}"
    text="${text//\"/&quot;}"
    text="${text//\'/&#39;}"

    printf '%s' "$text"
}

html_escape_file() {
    local file="$1"
    local line

    while IFS= read -r line || [[ -n "$line" ]]; do
        html_escape "$line"
        printf '\n'
    done < "$file"
}

status_class() {
    case "$1" in
        passed) printf 'status-pass' ;;
        failed) printf 'status-fail' ;;
        skipped) printf 'status-skip' ;;
        *) printf 'status-neutral' ;;
    esac
}

print_result_line() {
    local title="$1"
    local status="$2"
    local summary="$3"
    local note="${4:-}"

    case "$status" in
        passed)
            printf '%b[PASS]%b %-30s %s\n' "${GREEN}" "${NC}" "$title" "$summary"
            ;;
        failed)
            printf '%b[FAIL]%b %-30s %s\n' "${RED}" "${NC}" "$title" "$summary"
            ;;
        skipped)
            printf '%b[SKIP]%b %-30s %s\n' "${YELLOW}" "${NC}" "$title" "$note"
            ;;
        *)
            printf '%b[%s]%b %-30s %s\n' "${YELLOW}" "${status^^}" "${NC}" "$title" "$summary"
            ;;
    esac
}

extract_summary() {
    local title="$1"
    local log_file="$2"
    local summary=""

    if [[ ! -f "$log_file" ]]; then
        printf 'No log captured'
        return 0
    fi

    case "$title" in
        *Ping*)
            summary="$(grep -E 'packets transmitted|rtt min/avg|max|round-trip min/avg|max' "$log_file" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g' || true)"
            ;;
        *Traceroute*)
            summary="$(awk '/^[[:space:]]*[0-9]+[[:space:]]/ {hop=$0} END {print hop}' "$log_file" 2>/dev/null || true)"
            ;;
        *MTR*)
            summary="$(awk '/^[[:space:]]*[0-9]+[[:space:]]/ {row=$0} END {print row}' "$log_file" 2>/dev/null || true)"
            ;;
        *TCP*)
            summary="$(grep -E 'sender|receiver' "$log_file" 2>/dev/null | tail -n 2 | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g' || true)"
            ;;
        *UDP*)
            summary="$(grep -E 'sender|receiver' "$log_file" 2>/dev/null | tail -n 2 | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g' || true)"
            ;;
        *HTTP*)
            summary="$(grep -E 'Download Speed:' "$log_file" 2>/dev/null | tail -n 1 || true)"
            ;;
        *)
            summary="$(tail -n 1 "$log_file" 2>/dev/null || true)"
            ;;
    esac

    if [[ -z "$summary" ]]; then
        summary="See log"
    fi

    printf '%s' "$summary"
}

run_test() {
    local title="$1"
    local log_file="$2"
    shift 2
    local status summary

    print_info "$title"

    if "$@" 2>&1 | tee "$log_file"; then
        status=0
    else
        status=${PIPESTATUS[0]}
    fi

    summary="$(extract_summary "$title" "$log_file")"

    if [[ $status -eq 0 ]]; then
        PASSED_TESTS+=("$title")
        append_result "$title" "passed" "$summary" "$log_file" ""
        print_result_line "$title" "passed" "$summary"
        return 0
    fi

    FAILED_TESTS+=("$title")
    append_result "$title" "failed" "$summary" "$log_file" "exit code $status"
    print_result_line "$title" "failed" "$summary" "exit code $status"
    return 0
}

skip_test() {
    local title="$1"
    local reason="$2"

    SKIPPED_TESTS+=("$title")
    append_result "$title" "skipped" "$reason" "" "$reason"
    print_result_line "$title" "skipped" "" "$reason"
}

generate_html_report() {
    local report_file="$1"
    local i
    local total=${#RESULT_TITLES[@]}

    {
        cat <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>NetTest Report</title>
<style>
body{font-family:Arial,Helvetica,sans-serif;margin:0;background:#0f1115;color:#e8edf5}
.wrap{max-width:1180px;margin:0 auto;padding:24px}
.hero{background:#151922;border:1px solid #252b36;border-radius:14px;padding:20px;margin-bottom:18px}
.hero h1{margin:0 0 8px;font-size:28px}
.meta{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px;margin-top:16px}
.card{background:#0b0e13;border:1px solid #252b36;border-radius:12px;padding:12px}
.label{font-size:12px;color:#8e98a8;text-transform:uppercase;letter-spacing:.04em}
.value{margin-top:6px;font-size:16px;word-break:break-word}
table{width:100%;border-collapse:collapse;margin-top:16px;background:#0b0e13;border:1px solid #252b36;border-radius:12px;overflow:hidden}
th,td{padding:12px;border-bottom:1px solid #252b36;vertical-align:top;text-align:left}
th{font-size:12px;color:#8e98a8;text-transform:uppercase;letter-spacing:.04em}
tr:last-child td{border-bottom:0}
.badge{display:inline-flex;align-items:center;padding:3px 10px;border-radius:999px;font-size:12px;font-weight:700}
.status-pass{background:#12361f;color:#8ff0b3}
.status-fail{background:#3a1416;color:#ffabab}
.status-skip{background:#312a12;color:#ffe28a}
.status-neutral{background:#263041;color:#cfd8e3}
.logs{margin-top:18px}
details{background:#0b0e13;border:1px solid #252b36;border-radius:12px;padding:12px;margin-bottom:12px}
summary{cursor:pointer;font-weight:700}
pre{white-space:pre-wrap;word-break:break-word;background:#06080c;border:1px solid #252b36;border-radius:10px;padding:12px;overflow:auto}
.muted{color:#8e98a8}
</style>
</head>
<body>
<div class="wrap">
<section class="hero">
  <h1>NetTest Report</h1>
  <div class="muted">Generated at $(html_escape "$(date)")</div>
  <div class="meta">
    <div class="card"><div class="label">Total</div><div class="value">$(html_escape "$total")</div></div>
    <div class="card"><div class="label">Passed</div><div class="value">$(html_escape "${#PASSED_TESTS[@]}")</div></div>
    <div class="card"><div class="label">Failed</div><div class="value">$(html_escape "${#FAILED_TESTS[@]}")</div></div>
    <div class="card"><div class="label">Skipped</div><div class="value">$(html_escape "${#SKIPPED_TESTS[@]}")</div></div>
    <div class="card"><div class="label">Target</div><div class="value">$(html_escape "$TARGET")</div></div>
    <div class="card"><div class="label">IPERF Server</div><div class="value">$(html_escape "${IPERF_SERVER:-$TARGET}")</div></div>
    <div class="card"><div class="label">IPERF Port</div><div class="value">$(html_escape "$IPERF_PORT")</div></div>
    <div class="card"><div class="label">Report File</div><div class="value">$(html_escape "$report_file")</div></div>
  </div>
</section>

<section>
  <table>
    <thead>
      <tr>
        <th>Test</th>
        <th>Status</th>
        <th>Summary</th>
        <th>Note</th>
      </tr>
    </thead>
    <tbody>
EOF

        for i in "${!RESULT_TITLES[@]}"; do
            local title="${RESULT_TITLES[$i]}"
            local status="${RESULT_STATUSES[$i]}"
            local summary="${RESULT_SUMMARIES[$i]}"
            local note="${RESULT_NOTES[$i]}"
            local css_class
            css_class="$(status_class "$status")"

            printf '      <tr>\n'
            printf '        <td>%s</td>\n' "$(html_escape "$title")"
            printf '        <td><span class="badge %s">%s</span></td>\n' "$css_class" "$(html_escape "${status^^}")"
            printf '        <td>%s</td>\n' "$(html_escape "$summary")"
            printf '        <td>%s</td>\n' "$(html_escape "$note")"
            printf '      </tr>\n'
        done

        cat <<EOF
    </tbody>
  </table>
</section>

<section class="logs">
  <h2>Logs</h2>
EOF

        for i in "${!RESULT_TITLES[@]}"; do
            local title="${RESULT_TITLES[$i]}"
            local status="${RESULT_STATUSES[$i]}"
            local summary="${RESULT_SUMMARIES[$i]}"
            local log_file="${RESULT_LOG_FILES[$i]}"
            local note="${RESULT_NOTES[$i]}"
            local css_class
            local open_attr=""
            css_class="$(status_class "$status")"
            if [[ "$status" == "failed" ]]; then
                open_attr=" open"
            fi

            printf '<details%s>\n' "$open_attr"
            printf '  <summary><span class="badge %s">%s</span> %s</summary>\n' "$css_class" "$(html_escape "${status^^}")" "$(html_escape "$title")"
            printf '  <div class="muted" style="margin-top:8px">Summary: %s</div>\n' "$(html_escape "$summary")"
            if [[ -n "$note" ]]; then
                printf '  <div class="muted">Note: %s</div>\n' "$(html_escape "$note")"
            fi
            if [[ -n "$log_file" && -f "$log_file" ]]; then
                printf '  <pre>'
                html_escape_file "$log_file"
                printf '</pre>\n'
            else
                printf '  <div class="muted">No log file available.</div>\n'
            fi
            printf '</details>\n'
        done

        cat <<EOF
</section>
</div>
</body>
</html>
EOF
    } > "$report_file"
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

build_report_file() {
    local run_ts="$1"
    local slug

    slug="$(printf '%s' "${TARGET:-nettest}" | sed 's/[^A-Za-z0-9._-]/_/g')"
    REPORT_FILE="$LOG_DIR/nettest_${slug}_${run_ts}.html"
}

server_mode() {
    local pid=""

    if [[ -f "$SERVER_PID_FILE" ]]; then
        pid="$(<"$SERVER_PID_FILE")"
        if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
            print_warn "iperf3 server already running (PID $pid)"
            print_info "Listening on TCP/$IPERF_PORT"
            return 0
        fi
    fi

    print_info "Starting iperf3 server on port $IPERF_PORT..."

    nohup iperf3 -s -p "$IPERF_PORT" > "$SERVER_LOG_FILE" 2>&1 &
    pid=$!
    echo "$pid" > "$SERVER_PID_FILE"

    print_info "iperf3 server started (PID $pid)"
    print_info "Listening on TCP/$IPERF_PORT"
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
    build_report_file "$run_ts"

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
    if ((${#FAILED_TESTS[@]} > 0)); then
        print_warn "Failed: ${#FAILED_TESTS[@]}"
        print_warn "Failed tests: ${FAILED_TESTS[*]}"
    else
        print_info "Failed: 0"
    fi

    if ((${#SKIPPED_TESTS[@]} > 0)); then
        print_warn "Skipped: ${#SKIPPED_TESTS[@]}"
        print_warn "Skipped tests: ${SKIPPED_TESTS[*]}"
    else
        print_info "Skipped: 0"
    fi

    if [[ -n "$REPORT_FILE" ]]; then
        print_info "HTML report: $REPORT_FILE"
    fi
}

finalize_run() {
    if [[ -n "$REPORT_FILE" && ${#RESULT_TITLES[@]} -gt 0 ]]; then
        generate_html_report "$REPORT_FILE"
    fi
    print_summary
}

loop_mode() {
    require_target

    while true; do
        reset_run_state
        print_warn "Loop test started: $(date)"

        client_mode
        generate_html_report "$REPORT_FILE"
        print_summary

        print_warn "Sleeping ${LOOP_SLEEP_SECONDS} seconds..."
        sleep "$LOOP_SLEEP_SECONDS"
    done
}

normalize_args
reset_run_state

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

if [[ "$MODE" != "server" ]]; then
    finalize_run
fi
