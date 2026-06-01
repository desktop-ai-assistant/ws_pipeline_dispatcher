#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

ROOT_DIR=${ROOT_DIR:-$SCRIPT_DIR/.log/udp_demo}
DB_PATH=${DB_PATH:-$ROOT_DIR/clips.db}
SESSION=${SESSION:-demo_udp_session}
HOST=${HOST:-127.0.0.1}
PORT=${PORT:-10005}
MAX_CHUNKS=${MAX_CHUNKS:-0}
SEGMENT_TIME=${SEGMENT_TIME:-1.0}
PREPARE_MAX_CHUNKS=${PREPARE_MAX_CHUNKS:-0}
SEND_DELAY=${SEND_DELAY:-0.001}
LOG_EVERY=${LOG_EVERY:-1}
MODE=${MODE:-demo}
EXTRACT_OUT_DIR=${EXTRACT_OUT_DIR:-$ROOT_DIR/extracted}
EXTRACT_INTERVAL=${EXTRACT_INTERVAL:-1}
LIVE_EXTRACT=${LIVE_EXTRACT:-1}
SEGMENT_DIR=${SEGMENT_DIR:-$SCRIPT_DIR/.log/segments}

run_extract_once() {
    if [ ! -f "$DB_PATH" ]; then
        return 1
    fi
    "$SCRIPT_DIR/extract_udp_clips.sh" \
        --db "$DB_PATH" \
        --session "$SESSION" \
        --out-dir "$EXTRACT_OUT_DIR"
}

start_live_extract() {
    if [ "$LIVE_EXTRACT" = "0" ]; then
        return 0
    fi
    (
        last_state=
        while :; do
            if [ -f "$DB_PATH" ]; then
                state=$(stat -c '%Y:%s' "$DB_PATH" 2>/dev/null || true)
                if [ -n "$state" ] && [ "$state" != "$last_state" ]; then
                    last_state=$state
                    run_extract_once || true
                fi
            fi
            sleep "$EXTRACT_INTERVAL"
        done
    ) &
    extract_pid=$!
    printf '[full-run] live extraction enabled interval=%ss out=%s\n' "$EXTRACT_INTERVAL" "$EXTRACT_OUT_DIR" >&2
}

stop_live_extract() {
    if [ "${extract_pid:-}" ]; then
        kill "$extract_pid" 2>/dev/null || true
        wait "$extract_pid" 2>/dev/null || true
        extract_pid=
    fi
}

cleanup() {
    stop_live_extract
    if [ "${server_pid:-}" ]; then
        "$SCRIPT_DIR/udp_stream_data_client.sh" --host "$HOST" --port "$PORT" --shutdown >/dev/null 2>&1 || true
        wait "$server_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

cd "$WORKSPACE_ROOT"

printf '[full-run] cleaning %s\n' "$ROOT_DIR" >&2
rm -rf "$ROOT_DIR"
mkdir -p "$ROOT_DIR"

printf '[full-run] building binaries\n' >&2
make

printf '[full-run] preparing reusable segments dir=%s\n' "$SEGMENT_DIR" >&2
SEGMENT_DIR="$SEGMENT_DIR" SEGMENT_TIME="$SEGMENT_TIME" MAX_CHUNKS="$PREPARE_MAX_CHUNKS" "$SCRIPT_DIR/prepare_segments.sh"

printf '[full-run] starting server root=%s db=%s\n' "$ROOT_DIR" "$DB_PATH" >&2
"$SCRIPT_DIR/udp_stream_data_server.sh" \
    --host "$HOST" \
    --port "$PORT" \
    --root-dir "$ROOT_DIR" \
    --db "$DB_PATH" &
server_pid=$!

sleep 0.3
start_live_extract

printf '[full-run] sending session=%s mode=%s max_chunks=%s\n' "$SESSION" "$MODE" "$MAX_CHUNKS" >&2
"$SCRIPT_DIR/udp_stream_data_client.sh" \
    --host "$HOST" \
    --port "$PORT" \
    --session "$SESSION" \
    --mode "$MODE" \
    --max-chunks "$MAX_CHUNKS" \
    --segment-time "$SEGMENT_TIME" \
    --segment-dir "$SEGMENT_DIR" \
    --delay "$SEND_DELAY" \
    --log-every "$LOG_EVERY" \
    --extract-db "$DB_PATH" \
    --extract-out-dir "$EXTRACT_OUT_DIR" \
    --no-extract

printf '[full-run] stopping server\n' >&2
"$SCRIPT_DIR/udp_stream_data_client.sh" --host "$HOST" --port "$PORT" --shutdown
wait "$server_pid"
server_pid=

stop_live_extract
run_extract_once || true

printf '[full-run] clips db: %s\n' "$DB_PATH" >&2
"$WORKSPACE_ROOT/.build/clip_store" --db "$DB_PATH" --list || true

printf '[full-run] extracted output: %s\n' "$EXTRACT_OUT_DIR" >&2
find "$EXTRACT_OUT_DIR" -maxdepth 2 -type f -print 2>/dev/null || true
