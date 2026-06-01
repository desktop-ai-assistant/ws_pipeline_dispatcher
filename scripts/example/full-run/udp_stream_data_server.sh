#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

export PIPELINE_DISPATCHER="${PIPELINE_DISPATCHER:-$WORKSPACE_ROOT/.build/pipeline_dispatcher}"
exec python3 "$SCRIPT_DIR/udp_stream_data_server.py" "$@"
