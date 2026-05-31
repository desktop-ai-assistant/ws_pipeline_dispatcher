#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$WORKSPACE_ROOT"

LOG_PARSE="${LOG_PARSE:-$WORKSPACE_ROOT/.build/log_parse}"
OUT_DIR="$WORKSPACE_ROOT/scripts/example/applets/.log/log-parse"
RAW_LOG="$OUT_DIR/fsm.raw.log"
JSONL_INPUT="$OUT_DIR/events.input.jsonl"
FULL_LOG="$OUT_DIR/full-events.jsonl"
JSONL_FULL_LOG="$OUT_DIR/full-jsonl-events.jsonl"
SUMMARY="$OUT_DIR/summary.log"

REGEX='^([0-9]+) ([A-Z]+) session=([^ ]+) type=([^ ]+) duration=([0-9]+) bytes=([0-9]+) path=([^ ]+)$'
FIELDS='ts,level,session_id,type,duration,bytes,path'

mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR"/*

make .build/log_parse >/dev/null

show_file() {
    local label=$1
    local file=$2

    printf '  %s (%s)\n' "$label" "${file#$OUT_DIR/}"
    if [ -s "$file" ]; then
        while IFS= read -r line; do
            printf '    %s\n' "$line"
        done <"$file"
    else
        printf '    (empty)\n'
    fi
}

run_stdout_stderr() {
    local stdout_file=$1
    local stderr_file=$2
    shift 2
    "$@" >"$stdout_file" 2>"$stderr_file"
    show_file "stdout" "$stdout_file"
    if [ -s "$stderr_file" ]; then
        show_file "stderr" "$stderr_file"
    fi
    printf '\n'
}

cat >"$RAW_LOG" <<'LOG'
1747065600 INFO session=sess_A type=data duration=0 bytes=4096 path=/tmp/sess_A.bin
1747065601 WARN session=sess_A type=gap duration=0 bytes=0 path=/tmp/sess_A.bin
1747065602 INFO session=sess_A type=clip duration=5 bytes=4096 path=/tmp/clips/sess_A_0.bin
1747065603 INFO session=sess_B type=clip duration=3 bytes=1024 path=/tmp/clips/sess_B_0.bin
1747065604 ERROR session=sess_B type=late_reject duration=0 bytes=0 path=/tmp/sess_B.bin
1747065605 INFO session=sess_A type=clip duration=7 bytes=8192 path=/tmp/clips/sess_A_1.bin
LOG

cat >"$JSONL_INPUT" <<'JSONL'
{"type":"clip","session_id":"sess_A","ts":1747065602,"path":"/tmp/clips/sess_A_0.bin","duration":5,"bytes":4096,"complete":true}
{"type":"heartbeat","session_id":"sess_A","ts":1747065603,"path":"/tmp/runtime","duration":0,"bytes":0,"complete":true}
{"type":"clip","session_id":"sess_B","ts":1747065604,"path":"/tmp/tmpfile","duration":3,"bytes":1024,"complete":false}
{"type":"clip","session_id":"sess_A","ts":1747065605,"path":"/tmp/clips/sess_A_1.bin","duration":7,"bytes":8192,"complete":true}
JSONL

printf '\n[1] Regex parse raw FSM log to JSONL\n'
run_stdout_stderr "$OUT_DIR/regex.jsonl" "$OUT_DIR/regex.stderr.log" \
    "$LOG_PARSE" --regex "$REGEX" --fields "$FIELDS" --format json <"$RAW_LOG"

printf '[2] Regex parse raw FSM log to CSV\n'
run_stdout_stderr "$OUT_DIR/regex.csv" "$OUT_DIR/regex-csv.stderr.log" \
    "$LOG_PARSE" --regex "$REGEX" --fields "$FIELDS" --format csv <"$RAW_LOG"

printf '[3] Regex parse + filter only clip records\n'
run_stdout_stderr "$OUT_DIR/regex.filter.type-clip.jsonl" "$OUT_DIR/regex-filter.stderr.log" \
    "$LOG_PARSE" --regex "$REGEX" --fields "$FIELDS" --filter type=clip --format json <"$RAW_LOG"

printf '[4] Build full structured log while forwarding clip records\n'
run_stdout_stderr "$OUT_DIR/build-full-log.stdout.jsonl" "$OUT_DIR/build-full-log.stderr.log" \
    "$LOG_PARSE" --regex "$REGEX" --fields "$FIELDS" --build-full-log "$FULL_LOG" --filter type=clip <"$RAW_LOG"

printf '[5] Count clip records from raw FSM log\n'
run_stdout_stderr "$OUT_DIR/count.type-clip.log" "$OUT_DIR/count.stderr.log" \
    "$LOG_PARSE" --regex "$REGEX" --fields "$FIELDS" --filter type=clip --format count <"$RAW_LOG"

printf '[6] Aggregate clip bytes and durations\n'
printf '  sum bytes\n'
run_stdout_stderr "$OUT_DIR/sum.bytes.type-clip.log" "$OUT_DIR/sum.stderr.log" \
    "$LOG_PARSE" --regex "$REGEX" --fields "$FIELDS" --filter type=clip --sum bytes <"$RAW_LOG"
printf '  avg duration\n'
run_stdout_stderr "$OUT_DIR/avg.duration.type-clip.log" "$OUT_DIR/avg.stderr.log" \
    "$LOG_PARSE" --regex "$REGEX" --fields "$FIELDS" --filter type=clip --avg duration <"$RAW_LOG"
printf '  max bytes\n'
run_stdout_stderr "$OUT_DIR/max.bytes.type-clip.log" "$OUT_DIR/max.stderr.log" \
    "$LOG_PARSE" --regex "$REGEX" --fields "$FIELDS" --filter type=clip --max bytes <"$RAW_LOG"
printf '  min duration\n'
run_stdout_stderr "$OUT_DIR/min.duration.type-clip.log" "$OUT_DIR/min.stderr.log" \
    "$LOG_PARSE" --regex "$REGEX" --fields "$FIELDS" --filter type=clip --min duration <"$RAW_LOG"

printf '[7] Filter existing JSONL records\n'
printf '  complete=true\n'
run_stdout_stderr "$OUT_DIR/jsonl.filter.complete-true.jsonl" "$OUT_DIR/jsonl-complete.stderr.log" \
    "$LOG_PARSE" --filter complete=true <"$JSONL_INPUT"
printf '  path contains /clips/\n'
run_stdout_stderr "$OUT_DIR/jsonl.filter.path-clips.jsonl" "$OUT_DIR/jsonl-path.stderr.log" \
    "$LOG_PARSE" --filter 'path~/clips/' <"$JSONL_INPUT"
printf '  ts > 1747065603\n'
run_stdout_stderr "$OUT_DIR/jsonl.filter.ts-gt.jsonl" "$OUT_DIR/jsonl-ts.stderr.log" \
    "$LOG_PARSE" --filter 'ts>1747065603' <"$JSONL_INPUT"
printf '  type != heartbeat count\n'
run_stdout_stderr "$OUT_DIR/jsonl.count.type-not-heartbeat.log" "$OUT_DIR/jsonl-count.stderr.log" \
    "$LOG_PARSE" --filter 'type!=heartbeat' --format count <"$JSONL_INPUT"

printf '[8] Build full log from JSONL input while filtering stdout\n'
run_stdout_stderr "$OUT_DIR/jsonl.build-full-log.stdout.jsonl" "$OUT_DIR/jsonl-build-full-log.stderr.log" \
    "$LOG_PARSE" --build-full-log "$JSONL_FULL_LOG" --filter type=clip <"$JSONL_INPUT"

printf '[9] Capture malformed input diagnostics\n'
printf 'bad line\n' | "$LOG_PARSE" --filter type=clip >"$OUT_DIR/malformed-json.stdout.log" 2>"$OUT_DIR/malformed-json.stderr.log" || true
show_file "malformed JSON stdout" "$OUT_DIR/malformed-json.stdout.log"
show_file "malformed JSON stderr" "$OUT_DIR/malformed-json.stderr.log"
printf '\n'
printf 'this line does not match\n' | "$LOG_PARSE" --regex "$REGEX" --fields "$FIELDS" --format json >"$OUT_DIR/regex-no-match.stdout.log" 2>"$OUT_DIR/regex-no-match.stderr.log" || true
show_file "regex no-match stdout" "$OUT_DIR/regex-no-match.stdout.log"
show_file "regex no-match stderr" "$OUT_DIR/regex-no-match.stderr.log"
printf '\n'

cat >"$SUMMARY" <<EOF
log_parse demo artifacts
========================

Input files:
  $RAW_LOG
  $JSONL_INPUT

Core capabilities shown:
  - regex-based field extraction from raw FSM-style .log lines
  - JSONL output
  - CSV output
  - filter expressions: =, !=, >, ~
  - count mode
  - real-time aggregate statistics: sum, avg, max, min
  - --build-full-log for full structured JSONL audit/replay logs
  - malformed input diagnostics on stderr

Important outputs:
  regex.jsonl
  regex.csv
  regex.filter.type-clip.jsonl
  full-events.jsonl
  build-full-log.stdout.jsonl
  count.type-clip.log
  sum.bytes.type-clip.log
  avg.duration.type-clip.log
  max.bytes.type-clip.log
  min.duration.type-clip.log
  jsonl.filter.complete-true.jsonl
  jsonl.filter.path-clips.jsonl
  jsonl.filter.ts-gt.jsonl
  jsonl.count.type-not-heartbeat.log
  full-jsonl-events.jsonl
  malformed-json.stderr.log
  regex-no-match.stderr.log
EOF

printf '\nlog_parse demo complete. Artifacts written to:\n  %s\n' "$OUT_DIR"
