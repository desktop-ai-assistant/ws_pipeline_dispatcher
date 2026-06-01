#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

INPUT=${INPUT:-$SCRIPT_DIR/videoplayback.mp4}
SEGMENT_DIR=${SEGMENT_DIR:-$SCRIPT_DIR/.log/segments}
SEGMENT_TIME=${SEGMENT_TIME:-1.0}
MAX_CHUNKS=${MAX_CHUNKS:-0}
FFMPEG=${FFMPEG:-ffmpeg}
FORCE=${FORCE:-0}

if [ ! -f "$INPUT" ]; then
    printf '[prepare-segments] input not found: %s\n' "$INPUT" >&2
    exit 1
fi

if [ "$FORCE" = "1" ]; then
    rm -rf "$SEGMENT_DIR"
fi
mkdir -p "$SEGMENT_DIR"

existing_count=$(find "$SEGMENT_DIR" -maxdepth 1 -name 'seg_*.ts' -type f | wc -l)
if [ "$existing_count" -gt 0 ]; then
    printf '[prepare-segments] reuse %s existing segments in %s\n' "$existing_count" "$SEGMENT_DIR" >&2
    exit 0
fi

printf '[prepare-segments] generating MPEG-TS segments input=%s out=%s segment_time=%s max_chunks=%s\n' \
    "$INPUT" "$SEGMENT_DIR" "$SEGMENT_TIME" "$MAX_CHUNKS" >&2

set -- \
    "$FFMPEG" \
    -y \
    -hide_banner \
    -loglevel error \
    -i "$INPUT" \
    -map 0:v:0 \
    -an \
    -c:v libx264 \
    -preset veryfast \
    -tune zerolatency \
    -b:v 220k \
    -maxrate 220k \
    -bufsize 440k \
    -vf scale=320:-2 \
    -force_key_frames "expr:gte(t,n_forced*$SEGMENT_TIME)" \
    -f segment \
    -segment_format mpegts \
    -segment_time "$SEGMENT_TIME" \
    -reset_timestamps 1

if [ "$MAX_CHUNKS" -gt 0 ]; then
    set -- "$@" -t "$(python3 -c "print(float('$SEGMENT_TIME') * int('$MAX_CHUNKS'))")"
fi

"$@" "$SEGMENT_DIR/seg_%06d.ts"

generated_count=$(find "$SEGMENT_DIR" -maxdepth 1 -name 'seg_*.ts' -type f | wc -l)
printf '[prepare-segments] generated %s segments\n' "$generated_count" >&2
