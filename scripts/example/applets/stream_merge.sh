#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$WORKSPACE_ROOT"

STREAM_MERGE="${STREAM_MERGE:-$WORKSPACE_ROOT/.build/stream_merge}"
OUT_DIR="$WORKSPACE_ROOT/scripts/example/applets/.log/stream-merge"
SUMMARY="$OUT_DIR/summary.log"
SM_PID=""

mkdir -p "$OUT_DIR"
rm -rf "$OUT_DIR"/*

make .build/stream_merge >/dev/null

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

write_chunk() {
    local bin=$1
    local meta=$2
    local bytes=$3
    local record=$4

    printf '%b' "$bytes" >>"$bin"
    printf '%s\n' "$record" >>"$meta"
}

run_stream_merge() {
    local session=$1
    local src_dir=$2
    local clip_secs=$3
    local idle_secs=$4
    local stdout_file=$5
    local stderr_file=$6

    "$STREAM_MERGE" --clip-secs "$clip_secs" --idle-secs "$idle_secs" \
        "$session" "$src_dir" >"$stdout_file" 2>"$stderr_file" &
    SM_PID=$!
}

wait_for_pid() {
    local pid=$1
    local label=$2

    for _ in 1 2 3 4 5 6 7 8 9 10; do
        sleep 0.1
        kill -0 "$pid" 2>/dev/null || break
    done
    if kill -0 "$pid" 2>/dev/null; then
        printf '  warning: %s still running; terminating\n' "$label"
        kill "$pid" 2>/dev/null || true
    fi
    wait "$pid" || true
}

printf '\nstream_merge field guide\n'
printf '========================\n'
printf 'Input sidecar metadata fields:\n'
printf '  kind      record category; stream_merge currently processes kind=data\n'
printf '  sequence  monotonic chunk sequence used to detect late/duplicate/gap records\n'
printf '  offset    byte offset of this chunk inside the session-level .bin file\n'
printf '  length    byte length of this chunk, not time duration\n'
printf '  ts_ms     source timestamp in milliseconds; used for clip window boundaries\n'
printf 'Output clip JSON fields:\n'
printf '  type      emitted event type; clip records are sent downstream\n'
printf '  ts        clip start timestamp in seconds, derived from ts_ms / 1000\n'
printf '  path      metadata pointer path for the session/clip artifact\n'
printf '  offset    byte offset where the emitted clip range starts\n'
printf '  length    total byte length of the emitted clip range\n'
printf '  complete  true for normal/window/final flush, false for partial clips\n'

printf '\n[1] Normal time-window clip emission\n'
printf '  note: the boundary chunk at 5000ms triggers the previous window flush and becomes the next window start\n'
SESSION="sess_window"
SRC="$OUT_DIR/window-session"
mkdir -p "$SRC"
: >"$SRC/$SESSION.bin"
: >"$SRC/$SESSION.meta.jsonl"
run_stream_merge "$SESSION" "$SRC" 5 10 "$OUT_DIR/window.stdout.jsonl" "$OUT_DIR/window.stderr.log"
pid=$SM_PID
sleep 0.05
write_chunk "$SRC/$SESSION.bin" "$SRC/$SESSION.meta.jsonl" '\x00\x01\x02\x03' \
    '{"kind":"data","sequence":1,"offset":0,"length":4,"ts_ms":0}'
sleep 0.05
write_chunk "$SRC/$SESSION.bin" "$SRC/$SESSION.meta.jsonl" '\x04\x05\x06\x07' \
    '{"kind":"data","sequence":2,"offset":4,"length":4,"ts_ms":3000}'
sleep 0.05
write_chunk "$SRC/$SESSION.bin" "$SRC/$SESSION.meta.jsonl" '\x08\x09\x0a\x0b' \
    '{"kind":"data","sequence":3,"offset":8,"length":4,"ts_ms":5000}'
sleep 0.05
touch "$SRC/.pipeline_end"
wait_for_pid "$pid" "$SESSION"
show_file "sidecar metadata" "$SRC/$SESSION.meta.jsonl"
show_file "stdout clips" "$OUT_DIR/window.stdout.jsonl"
show_file "stderr diagnostics" "$OUT_DIR/window.stderr.log"
printf '\n'

printf '[2] Continuity gap emits partial clip then restarts collection\n'
printf '  note: after sequence=1 offset=0 length=4, the FSM expects sequence=2 and offset=4\n'
printf '  note: sequence=5 offset=16 skips the expected chunk range, so the current clip is emitted as complete=false\n'
printf '  note: sequence=5 then starts a new clip; .pipeline_end final-flush emits that new clip as complete=true\n'
SESSION="sess_gap"
SRC="$OUT_DIR/gap-session"
mkdir -p "$SRC"
: >"$SRC/$SESSION.bin"
: >"$SRC/$SESSION.meta.jsonl"
run_stream_merge "$SESSION" "$SRC" 30 10 "$OUT_DIR/gap.stdout.jsonl" "$OUT_DIR/gap.stderr.log"
pid=$SM_PID
sleep 0.05
write_chunk "$SRC/$SESSION.bin" "$SRC/$SESSION.meta.jsonl" '\x00\x01\x02\x03' \
    '{"kind":"data","sequence":1,"offset":0,"length":4,"ts_ms":0}'
sleep 0.05
write_chunk "$SRC/$SESSION.bin" "$SRC/$SESSION.meta.jsonl" '\x10\x11\x12\x13' \
    '{"kind":"data","sequence":5,"offset":16,"length":4,"ts_ms":1000}'
sleep 0.05
touch "$SRC/.pipeline_end"
wait_for_pid "$pid" "$SESSION"
show_file "sidecar metadata" "$SRC/$SESSION.meta.jsonl"
show_file "stdout clips" "$OUT_DIR/gap.stdout.jsonl"
show_file "stderr diagnostics" "$OUT_DIR/gap.stderr.log"
printf '\n'

printf '[3] Idle timeout emits partial clip when input stalls\n'
SESSION="sess_idle"
SRC="$OUT_DIR/idle-session"
mkdir -p "$SRC"
: >"$SRC/$SESSION.bin"
: >"$SRC/$SESSION.meta.jsonl"
run_stream_merge "$SESSION" "$SRC" 30 1 "$OUT_DIR/idle.stdout.jsonl" "$OUT_DIR/idle.stderr.log"
pid=$SM_PID
sleep 0.05
write_chunk "$SRC/$SESSION.bin" "$SRC/$SESSION.meta.jsonl" '\xaa\xbb\xcc\xdd' \
    '{"kind":"data","sequence":1,"offset":0,"length":4,"ts_ms":0}'
sleep 1.3
touch "$SRC/.pipeline_end"
wait_for_pid "$pid" "$SESSION"
show_file "sidecar metadata" "$SRC/$SESSION.meta.jsonl"
show_file "stdout clips" "$OUT_DIR/idle.stdout.jsonl"
show_file "stderr diagnostics" "$OUT_DIR/idle.stderr.log"
printf '\n'

printf '[4] Invalid legacy metadata is rejected\n'
SESSION="sess_schema"
SRC="$OUT_DIR/schema-session"
mkdir -p "$SRC"
: >"$SRC/$SESSION.bin"
: >"$SRC/$SESSION.meta.jsonl"
run_stream_merge "$SESSION" "$SRC" 5 10 "$OUT_DIR/schema.stdout.jsonl" "$OUT_DIR/schema.stderr.log"
pid=$SM_PID
sleep 0.05
write_chunk "$SRC/$SESSION.bin" "$SRC/$SESSION.meta.jsonl" '\x00\x01\x02\x03' \
    '{"kind":"data","seq":1,"offset":0,"length":4,"ts_ms":0}'
sleep 0.05
touch "$SRC/.pipeline_end"
wait_for_pid "$pid" "$SESSION"
show_file "sidecar metadata" "$SRC/$SESSION.meta.jsonl"
show_file "stdout clips" "$OUT_DIR/schema.stdout.jsonl"
show_file "stderr diagnostics" "$OUT_DIR/schema.stderr.log"
printf '\n'

cat >"$SUMMARY" <<EOF
stream_merge demo artifacts
===========================

Output directory:
  $OUT_DIR

Capabilities shown:
  - reads session-level .bin plus .meta.jsonl sidecar
  - processes canonical metadata fields: kind, sequence, offset, length, ts_ms
  - emits clip JSON records to stdout
  - normal time-window boundary emits complete clips
  - sequence/offset gaps emit partial clips and restart collection
  - idle timeout emits partial clips when input stalls
  - malformed or legacy metadata is skipped with diagnostics on stderr

Important outputs:
  window.stdout.jsonl
  gap.stdout.jsonl
  idle.stdout.jsonl
  schema.stderr.log

Notes:
  stream_merge does not write the final clip media file. It emits metadata pointers
  containing path, offset, length, complete, and session_id for downstream stages.
EOF

printf 'stream_merge demo complete. Artifacts written to:\n  %s\n' "$OUT_DIR"
