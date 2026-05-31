#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$WORKSPACE_ROOT"

CLIP_STORE="${CLIP_STORE:-$WORKSPACE_ROOT/.build/clip_store}"
OUT_DIR="$WORKSPACE_ROOT/scripts/example/applets/.log/clip-store"
DB="$OUT_DIR/clips.db"
INPUT="$OUT_DIR/input.jsonl"
SUMMARY="$OUT_DIR/summary.log"

mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR"/*

make .build/clip_store >/dev/null

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

run_and_capture() {
    local output=$1
    shift
    "$@" >"$output"
    show_file "stdout" "$output"
    printf '\n'
}

snapshot_db() {
    local output=$1
    if [ -f "$DB" ]; then
        cp "$DB" "$output"
    else
        : >"$output"
    fi
    show_file "raw DB" "$output"
    printf '\n'
}

cat >"$INPUT" <<'JSONL'
{"type":"clip","session_id":"sess_A","ts":1000,"path":"/tmp/sess_A.bin","offset":0,"length":4096,"complete":true}
{"type":"clip","session_id":"sess_A","ts":6000,"path":"/tmp/sess_A.bin","offset":4096,"length":2048,"complete":false,"reason":"gap"}
{"type":"clip","session_id":"sess_B","ts":1000,"path":"/tmp/sess_B.bin","offset":0,"length":1024,"complete":true}
JSONL

printf '\n[1] Ingest structured records into compressed DB\n'
show_file "input JSONL" "$INPUT"
"$CLIP_STORE" --db "$DB" --ttl 300 <"$INPUT"
snapshot_db "$OUT_DIR/db.raw.before-update.log"

printf '[2] Querying sess_A:1000\n'
run_and_capture "$OUT_DIR/get.sess_A_1000.before-update.log" \
    "$CLIP_STORE" --db "$DB" --get sess_A:1000

printf '[3] Updating sess_A:1000 with a newer full JSON record\n'
printf '%s\n' \
    '{"type":"clip","session_id":"sess_A","ts":1000,"path":"/tmp/sess_A.bin","offset":0,"length":8192,"complete":true,"updated":true}' \
    | "$CLIP_STORE" --db "$DB" --ttl 300
snapshot_db "$OUT_DIR/db.raw.after-update.log"
printf '  latest value after update\n'
run_and_capture "$OUT_DIR/get.sess_A_1000.after-update.log" \
    "$CLIP_STORE" --db "$DB" --get sess_A:1000

printf '[4] Listing records by session prefix\n'
run_and_capture "$OUT_DIR/prefix.sess_A.log" \
    "$CLIP_STORE" --db "$DB" --prefix sess_A:

printf '[5] Listing all live records\n'
run_and_capture "$OUT_DIR/list.live.log" \
    "$CLIP_STORE" --db "$DB" --list

printf '[6] Demonstrating manual key-value set/get/delete\n'
"$CLIP_STORE" --db "$DB" --set manual:1=/tmp/manual.mp4
printf '  after --set manual:1=/tmp/manual.mp4\n'
run_and_capture "$OUT_DIR/set.manual.get.log" \
    "$CLIP_STORE" --db "$DB" --get manual:1
"$CLIP_STORE" --db "$DB" --delete manual:1
printf '  after --delete manual:1\n'
run_and_capture "$OUT_DIR/delete.manual.get.log" \
    "$CLIP_STORE" --db "$DB" --get manual:1

printf '[7] Storing a never-expire record with --ttl 0\n'
printf '%s\n' \
    '{"type":"clip","session_id":"sess_TTL","ts":1,"path":"/tmp/no_expire.bin","offset":0,"length":1,"complete":true,"ttl":"never"}' \
    | "$CLIP_STORE" --db "$DB" --ttl 0
run_and_capture "$OUT_DIR/ttl.never-expire.get.log" \
    "$CLIP_STORE" --db "$DB" --get sess_TTL:1

printf '[8] Compacting DB with --gc\n'
"$CLIP_STORE" --db "$DB" --gc
snapshot_db "$OUT_DIR/db.raw.after-gc.log"
printf '  live rows after GC\n'
run_and_capture "$OUT_DIR/list.live.after-gc.log" \
    "$CLIP_STORE" --db "$DB" --list

cat >"$SUMMARY" <<EOF
clip_store demo artifacts
=========================

Input JSONL:
  $INPUT

Compressed append-only DB:
  $DB

Key behavior:
  - stdin append mode stores full JSON records as values
  - lookup key is session_id:ts
  - DB rows are key<TAB>Z:base64(zlib(value))<TAB>expire_at
  - --get returns the decompressed latest live value
  - --prefix and --list return latest live rows
  - --delete writes a tombstone
  - --gc compacts duplicate, deleted, and expired rows
  - --ttl 0 stores records that never expire

Generated files:
  input.jsonl
  clips.db
  db.raw.before-update.log
  get.sess_A_1000.before-update.log
  db.raw.after-update.log
  get.sess_A_1000.after-update.log
  prefix.sess_A.log
  list.live.log
  set.manual.get.log
  delete.manual.get.log
  ttl.never-expire.get.log
  db.raw.after-gc.log
  list.live.after-gc.log
EOF

printf '\nclip_store demo complete. Artifacts written to:\n  %s\n' "$OUT_DIR"
