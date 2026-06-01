#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

ROOT_DIR=${ROOT_DIR:-/tmp/udp_demo}
DB_PATH=${DB_PATH:-$ROOT_DIR/clips.db}
SESSION=${SESSION:-demo_udp_session}
HOST=${HOST:-127.0.0.1}
PORT=${PORT:-10005}
MAX_CHUNKS=${MAX_CHUNKS:-0}
SEGMENT_TIME=${SEGMENT_TIME:-1.0}
SEND_DELAY=${SEND_DELAY:-0.001}
LOG_EVERY=${LOG_EVERY:-1}
MODE=${MODE:-demo}
EXTRACT_OUT_DIR=${EXTRACT_OUT_DIR:-$ROOT_DIR/extracted}

cleanup() {
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

printf '[full-run] starting server root=%s db=%s\n' "$ROOT_DIR" "$DB_PATH" >&2
"$SCRIPT_DIR/udp_stream_data_server.sh" \
    --host "$HOST" \
    --port "$PORT" \
    --root-dir "$ROOT_DIR" \
    --db "$DB_PATH" &
server_pid=$!

sleep 0.3

printf '[full-run] sending session=%s mode=%s max_chunks=%s\n' "$SESSION" "$MODE" "$MAX_CHUNKS" >&2
"$SCRIPT_DIR/udp_stream_data_client.sh" \
    --host "$HOST" \
    --port "$PORT" \
    --session "$SESSION" \
    --mode "$MODE" \
    --max-chunks "$MAX_CHUNKS" \
    --segment-time "$SEGMENT_TIME" \
    --delay "$SEND_DELAY" \
    --log-every "$LOG_EVERY" \
    --extract-db "$DB_PATH" \
    --extract-out-dir "$EXTRACT_OUT_DIR"

printf '[full-run] stopping server\n' >&2
"$SCRIPT_DIR/udp_stream_data_client.sh" --host "$HOST" --port "$PORT" --shutdown
wait "$server_pid"
server_pid=

printf '[full-run] clips db: %s\n' "$DB_PATH" >&2
"$WORKSPACE_ROOT/.build/clip_store" --db "$DB_PATH" --list || true

printf '[full-run] extracted output: %s\n' "$EXTRACT_OUT_DIR" >&2
find "$EXTRACT_OUT_DIR" -maxdepth 2 -type f -print 2>/dev/null || true
