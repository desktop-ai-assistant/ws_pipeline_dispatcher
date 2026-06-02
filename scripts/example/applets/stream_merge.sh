#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$WORKSPACE_ROOT"

STREAM_MERGE="${STREAM_MERGE:-$WORKSPACE_ROOT/.build/stream_merge}"
LOG_PARSE="${LOG_PARSE:-$WORKSPACE_ROOT/.build/log_parse}"
OUT_DIR="$WORKSPACE_ROOT/scripts/example/applets/.log/stream-merge"
SUMMARY="$OUT_DIR/summary.log"
TIMELINE="$OUT_DIR/session-timeline.all.jsonl"
SM_PID=""

mkdir -p "$OUT_DIR"
rm -rf "$OUT_DIR"/*

make .build/stream_merge .build/log_parse >/dev/null

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
printf 'Positioning:\n'
printf '  stream_merge is a filesystem-based, RTP-like stream assembler.\n'
printf '  Each .meta.jsonl row is treated like a packet descriptor for bytes already appended to .bin.\n'
printf '  It builds a clip timeline by validating continuity, not by blindly concatenating JSON rows.\n'
printf '\nInput packet descriptor fields:\n'
printf '  kind      record category; only kind=data participates in clip assembly\n'
printf '  sequence  monotonic packet order; detects duplicate, late, and skipped records\n'
printf '  offset    expected byte position in the append-only .bin artifact\n'
printf '  length    payload byte length; used to compute the next expected offset\n'
printf '  ts_ms     source timestamp; drives target clip windows\n'
printf '  continuous/byte_rate optional byte-time mapping for exact byte-range cuts\n'
printf '  events    optional chunk-level tags; merged into clip-level signal\n'
printf '\nOutput clip fields:\n'
printf '  offset/length     byte range inside the session .bin\n'
printf '  start/end/duration timeline derived from source timestamps\n'
printf '  boundary_mode     metadata_boundary or continuous_byte_range\n'
printf '  complete          true for normal/final windows, false for gap or idle partials\n'
printf '  events            deduplicated signals observed across the clip window\n'

printf '\n[1] Boundary-aligned chunks create clip windows and preserve event signal\n'
printf '  story: three packet descriptors arrive in order; seq 3 crosses the 5s target window.\n'
printf '  value: output is a clip byte range plus merged semantic events, not a raw metadata concat.\n'
SESSION="sess_window"
SRC="$OUT_DIR/window-session"
mkdir -p "$SRC"
: >"$SRC/$SESSION.bin"
: >"$SRC/$SESSION.meta.jsonl"
run_stream_merge "$SESSION" "$SRC" 5 10 "$OUT_DIR/window.stdout.jsonl" "$OUT_DIR/window.stderr.log"
pid=$SM_PID
sleep 0.05
write_chunk "$SRC/$SESSION.bin" "$SRC/$SESSION.meta.jsonl" '\x00\x01\x02\x03' \
    '{"kind":"data","sequence":1,"offset":0,"length":4,"ts_ms":0,"events":["motion"]}'
sleep 0.05
write_chunk "$SRC/$SESSION.bin" "$SRC/$SESSION.meta.jsonl" '\x04\x05\x06\x07' \
    '{"kind":"data","sequence":2,"offset":4,"length":4,"ts_ms":3000,"events":["person","motion"]}'
sleep 0.05
write_chunk "$SRC/$SESSION.bin" "$SRC/$SESSION.meta.jsonl" '\x08\x09\x0a\x0b' \
    '{"kind":"data","sequence":3,"offset":8,"length":4,"ts_ms":5000,"events":["vehicle"]}'
sleep 0.05
touch "$SRC/.pipeline_end"
wait_for_pid "$pid" "$SESSION"
show_file "packet descriptors" "$SRC/$SESSION.meta.jsonl"
show_file "clip timeline output" "$OUT_DIR/window.stdout.jsonl"
show_file "diagnostics" "$OUT_DIR/window.stderr.log"
printf '\n'

printf '[2] Continuous .bin can cut inside chunk boundaries by byte-rate\n'
printf '  story: two continuous chunks total 6000 bytes; byte_rate=1000 and target=5s.\n'
printf '  value: stream_merge emits a 5000-byte, 5000ms clip with boundary_mode=continuous_byte_range.\n'
SESSION="sess_continuous"
SRC="$OUT_DIR/continuous-session"
mkdir -p "$SRC"
: >"$SRC/$SESSION.bin"
: >"$SRC/$SESSION.meta.jsonl"
run_stream_merge "$SESSION" "$SRC" 5 10 "$OUT_DIR/continuous.stdout.jsonl" "$OUT_DIR/continuous.stderr.log"
pid=$SM_PID
sleep 0.05
write_chunk "$SRC/$SESSION.bin" "$SRC/$SESSION.meta.jsonl" '\x00\x01\x02\x03' \
    '{"kind":"data","sequence":1,"offset":0,"length":3000,"ts_ms":0,"continuous":true,"byte_rate":1000,"frame_align":1,"events":["pcm"]}'
sleep 0.05
write_chunk "$SRC/$SESSION.bin" "$SRC/$SESSION.meta.jsonl" '\x04\x05\x06\x07' \
    '{"kind":"data","sequence":2,"offset":3000,"length":3000,"ts_ms":3000,"continuous":true,"byte_rate":1000,"frame_align":1,"events":["voice"]}'
sleep 0.05
touch "$SRC/.pipeline_end"
wait_for_pid "$pid" "$SESSION"
show_file "packet descriptors" "$SRC/$SESSION.meta.jsonl"
show_file "clip timeline output" "$OUT_DIR/continuous.stdout.jsonl"
show_file "diagnostics" "$OUT_DIR/continuous.stderr.log"
printf '\n'

printf '[3] Sequence/offset gap becomes an explicit partial clip\n'
printf '  story: after seq=1 offset=0 length=4, the assembler expects seq=2 offset=4.\n'
printf '  value: seq=5 offset=16 is not hidden; current timeline is closed as complete=false.\n'
SESSION="sess_gap"
SRC="$OUT_DIR/gap-session"
mkdir -p "$SRC"
: >"$SRC/$SESSION.bin"
: >"$SRC/$SESSION.meta.jsonl"
run_stream_merge "$SESSION" "$SRC" 30 10 "$OUT_DIR/gap.stdout.jsonl" "$OUT_DIR/gap.stderr.log"
pid=$SM_PID
sleep 0.05
write_chunk "$SRC/$SESSION.bin" "$SRC/$SESSION.meta.jsonl" '\x00\x01\x02\x03' \
    '{"kind":"data","sequence":1,"offset":0,"length":4,"ts_ms":0,"events":["audio"]}'
sleep 0.05
write_chunk "$SRC/$SESSION.bin" "$SRC/$SESSION.meta.jsonl" '\x10\x11\x12\x13' \
    '{"kind":"data","sequence":5,"offset":16,"length":4,"ts_ms":1000,"events":["network_gap"]}'
sleep 0.05
touch "$SRC/.pipeline_end"
wait_for_pid "$pid" "$SESSION"
show_file "packet descriptors" "$SRC/$SESSION.meta.jsonl"
show_file "clip timeline output" "$OUT_DIR/gap.stdout.jsonl"
show_file "diagnostics" "$OUT_DIR/gap.stderr.log"
printf '\n'

printf '[4] Late or duplicate packet descriptors are rejected without corrupting the active clip\n'
printf '  story: seq=1 and seq=2 are accepted, then an old seq=1 descriptor arrives again.\n'
printf '  value: stream_merge guards the timeline state instead of double-counting old bytes.\n'
SESSION="sess_late"
SRC="$OUT_DIR/late-session"
mkdir -p "$SRC"
: >"$SRC/$SESSION.bin"
: >"$SRC/$SESSION.meta.jsonl"
run_stream_merge "$SESSION" "$SRC" 30 10 "$OUT_DIR/late.stdout.jsonl" "$OUT_DIR/late.stderr.log"
pid=$SM_PID
sleep 0.05
write_chunk "$SRC/$SESSION.bin" "$SRC/$SESSION.meta.jsonl" '\xaa\xbb\xcc\xdd' \
    '{"kind":"data","sequence":1,"offset":0,"length":4,"ts_ms":0,"events":["boot"]}'
sleep 0.05
write_chunk "$SRC/$SESSION.bin" "$SRC/$SESSION.meta.jsonl" '\xee\xff\x10\x11' \
    '{"kind":"data","sequence":2,"offset":4,"length":4,"ts_ms":1000,"events":["stable"]}'
sleep 0.05
printf '%s\n' '{"kind":"data","sequence":1,"offset":0,"length":4,"ts_ms":500,"events":["duplicate"]}' >>"$SRC/$SESSION.meta.jsonl"
sleep 0.05
touch "$SRC/.pipeline_end"
wait_for_pid "$pid" "$SESSION"
show_file "packet descriptors" "$SRC/$SESSION.meta.jsonl"
show_file "clip timeline output" "$OUT_DIR/late.stdout.jsonl"
show_file "diagnostics" "$OUT_DIR/late.stderr.log"
printf '\n'

printf '[5] Idle timeout turns a stalled stream into a partial timeline segment\n'
printf '  story: one descriptor arrives, then no more data appears before idle timeout.\n'
printf '  value: downstream sees an explicit incomplete clip instead of waiting forever.\n'
SESSION="sess_idle"
SRC="$OUT_DIR/idle-session"
mkdir -p "$SRC"
: >"$SRC/$SESSION.bin"
: >"$SRC/$SESSION.meta.jsonl"
run_stream_merge "$SESSION" "$SRC" 30 1 "$OUT_DIR/idle.stdout.jsonl" "$OUT_DIR/idle.stderr.log"
pid=$SM_PID
sleep 0.05
write_chunk "$SRC/$SESSION.bin" "$SRC/$SESSION.meta.jsonl" '\x20\x21\x22\x23' \
    '{"kind":"data","sequence":1,"offset":0,"length":4,"ts_ms":0,"events":["stall_start"]}'
sleep 1.3
touch "$SRC/.pipeline_end"
wait_for_pid "$pid" "$SESSION"
show_file "packet descriptors" "$SRC/$SESSION.meta.jsonl"
show_file "clip timeline output" "$OUT_DIR/idle.stdout.jsonl"
show_file "diagnostics" "$OUT_DIR/idle.stderr.log"
printf '\n'

printf '[6] Schema validation keeps non-canonical metadata out of the timeline\n'
printf '  story: legacy field seq is present, but canonical sequence is missing.\n'
printf '  value: malformed descriptors are diagnosed and skipped before they affect clip state.\n'
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
show_file "packet descriptors" "$SRC/$SESSION.meta.jsonl"
show_file "clip timeline output" "$OUT_DIR/schema.stdout.jsonl"
show_file "diagnostics" "$OUT_DIR/schema.stderr.log"
printf '\n'

: >"$TIMELINE"
for file in "$OUT_DIR"/*.stdout.jsonl; do
    [ -s "$file" ] || continue
    while IFS= read -r line; do
        printf '%s\n' "$line" >>"$TIMELINE"
    done <"$file"
done

printf '[7] Downstream view: query the generated timeline with log_parse\n'
printf '  story: stream_merge output is already Agent/query friendly JSONL.\n'
printf '  partial clips only\n'
"$LOG_PARSE" --filter complete=false <"$TIMELINE" >"$OUT_DIR/query.partial-clips.jsonl" 2>"$OUT_DIR/query.partial-clips.stderr.log"
show_file "partial clips" "$OUT_DIR/query.partial-clips.jsonl"
printf '  merged byte ranges longer than one chunk\n'
"$LOG_PARSE" --filter 'length>4' <"$TIMELINE" >"$OUT_DIR/query.merged-ranges.jsonl" 2>"$OUT_DIR/query.merged-ranges.stderr.log"
show_file "merged ranges" "$OUT_DIR/query.merged-ranges.jsonl"
printf '  continuous byte-range clips\n'
"$LOG_PARSE" --filter boundary_mode=continuous_byte_range <"$TIMELINE" >"$OUT_DIR/query.continuous-byte-range.jsonl" 2>"$OUT_DIR/query.continuous-byte-range.stderr.log"
show_file "continuous byte-range clips" "$OUT_DIR/query.continuous-byte-range.jsonl"
printf '  total clip count\n'
"$LOG_PARSE" --filter type=clip --format count <"$TIMELINE" >"$OUT_DIR/query.clip-count.log" 2>"$OUT_DIR/query.clip-count.stderr.log"
show_file "clip count" "$OUT_DIR/query.clip-count.log"
printf '\n'

cat >"$SUMMARY" <<EOF
stream_merge demo artifacts
===========================

Output directory:
  $OUT_DIR

Positioning shown:
  stream_merge is a filesystem-based, RTP-like stream assembler. It interprets
  .meta.jsonl rows as packet descriptors for bytes already appended to .bin,
  then produces a clip-level timeline for downstream stages and Agents.

Capabilities shown:
  - reads session-level .bin plus .meta.jsonl sidecar
  - validates canonical packet descriptor fields: kind, sequence, offset, length, ts_ms
  - creates time-window clips from continuous sequence/offset/timestamp metadata
  - cuts exact byte ranges for continuous streams with continuous=true and byte_rate
  - deduplicates chunk-level events into clip-level event signals
  - emits partial clips when sequence/offset gaps make continuity untrusted
  - rejects late/duplicate descriptors without corrupting active clip state
  - emits partial clips when a stream stalls past idle timeout
  - skips malformed or legacy metadata with stderr diagnostics
  - produces JSONL clip records that log_parse can filter and count downstream

Important outputs:
  window.stdout.jsonl
  continuous.stdout.jsonl
  gap.stdout.jsonl
  late.stdout.jsonl
  idle.stdout.jsonl
  schema.stderr.log
  session-timeline.all.jsonl
  query.partial-clips.jsonl
  query.merged-ranges.jsonl
  query.continuous-byte-range.jsonl
  query.clip-count.log

Notes:
  stream_merge does not decode media or write final clip media files. It emits
  trustworthy clip pointers containing path, offset, length, timing, complete,
  events, and session_id for downstream extraction/indexing stages.
EOF

printf 'stream_merge demo complete. Artifacts written to:\n  %s\n' "$OUT_DIR"
