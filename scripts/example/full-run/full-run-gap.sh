#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

export MODE="${MODE:-gap}"
export ROOT_DIR="${ROOT_DIR:-$SCRIPT_DIR/.log/udp_demo_gap}"
export EXTRACT_OUT_DIR="${EXTRACT_OUT_DIR:-$ROOT_DIR/extracted/.gap}"
export SESSION="${SESSION:-demo_udp_gap_session}"
export MAX_CHUNKS="${MAX_CHUNKS:-40}"
export LOG_EVERY="${LOG_EVERY:-1}"

printf '[full-run-gap] mode=%s session=%s root=%s extract=%s max_chunks=%s\n' \
    "$MODE" "$SESSION" "$ROOT_DIR" "$EXTRACT_OUT_DIR" "$MAX_CHUNKS" >&2

exec "$SCRIPT_DIR/full-run.sh"
