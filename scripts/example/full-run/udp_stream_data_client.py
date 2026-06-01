#!/usr/bin/env python3
import argparse
import base64
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
from tempfile import TemporaryDirectory


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Send demo UDP packets to udp_stream_data_server.py.")
    parser.add_argument("--host", default=os.environ.get("HOST", "127.0.0.1"), help="server host")
    parser.add_argument("--port", type=int, default=int(os.environ.get("PORT", "10005")), help="server port")
    parser.add_argument("--session", default=os.environ.get("SESSION", "demo_udp_session"), help="session id")
    parser.add_argument("--mode", choices=("demo", "gap"), default=os.environ.get("MODE", "demo"), help="packet sequence mode")
    parser.add_argument("--input", default=os.environ.get("INPUT", str(Path(__file__).with_name("videoplayback.mp4"))), help="input MP4 file or directory of .ts segments")
    parser.add_argument("--format", choices=("mpegts", "raw"), default=os.environ.get("STREAM_FORMAT", "mpegts"), help="send media-aligned MPEG-TS segments or legacy fixed-size raw chunks")
    parser.add_argument("--chunk-size", type=int, default=int(os.environ.get("CHUNK_SIZE", "32768")), help="raw mode bytes per DATASEQ packet")
    parser.add_argument("--segment-time", type=float, default=float(os.environ.get("SEGMENT_TIME", "1.0")), help="seconds per generated MPEG-TS segment")
    parser.add_argument("--segment-dir", default=os.environ.get("SEGMENT_DIR", ""), help="reuse/write MPEG-TS segments in this directory")
    parser.add_argument("--wire-fragment-size", type=int, default=int(os.environ.get("WIRE_FRAGMENT_SIZE", "32768")), help="bytes per UDP datagram when sending one segment")
    parser.add_argument("--max-chunks", type=int, default=int(os.environ.get("MAX_CHUNKS", "8")), help="maximum raw chunks or media segments to send; 0 streams until EOF")
    parser.add_argument("--ts-step-ms", type=int, default=int(os.environ.get("TS_STEP_MS", "0")), help="timestamp increment per raw chunk; 0 uses segment-time in mpegts mode")
    parser.add_argument("--ffmpeg", default=os.environ.get("FFMPEG", "ffmpeg"), help="ffmpeg binary used to generate MPEG-TS segments")
    parser.add_argument("--delay", type=float, default=float(os.environ.get("SEND_DELAY", "0.001")), help="sleep seconds between packets")
    parser.add_argument("--log-every", type=int, default=int(os.environ.get("LOG_EVERY", "1000")), help="log every N DATASEQ packets after the first few")
    parser.add_argument("--shutdown", action="store_true", help="ask the server to stop")
    return parser.parse_args()


def log(message: str) -> None:
    print(f"[udp-client] {message}", file=sys.stderr, flush=True)


def packet_payload(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def send_line(sock: socket.socket, host: str, port: int, line: str, log_packet: bool = True, delay: float = 0) -> None:
    sock.sendto(line.encode("utf-8"), (host, port))
    if log_packet:
        parts = line.split(" ", 3)
        if parts[0] == "DATASEQ" and len(parts) == 4:
            log(f"sent -> DATASEQ seq={parts[1]} ts_ms={parts[2]} payload_b64_len={len(parts[3])}")
        else:
            log(f"sent -> {line}")
    if delay > 0:
        time.sleep(delay)


def should_log_chunk(index: int, log_every: int) -> bool:
    return index <= 3 or (log_every > 0 and index % log_every == 0)


def stream_chunks(path: str, chunk_size: int, max_chunks: int):
    with open(path, "rb") as fp:
        sent = 0
        while max_chunks <= 0 or sent < max_chunks:
            chunk = fp.read(chunk_size)
            if not chunk:
                break
            sent += 1
            yield sent, chunk


def generate_segments(input_path: Path, out_dir: Path, segment_time: float, max_segments: int, ffmpeg: str):
    out_dir.mkdir(parents=True, exist_ok=True)
    existing = sorted(out_dir.glob("seg_*.ts"))
    if existing:
        return existing[:max_segments] if max_segments > 0 else existing

    cmd = [
        ffmpeg,
        "-y",
        "-hide_banner",
        "-loglevel",
        "error",
        "-i",
        str(input_path),
        "-map",
        "0:v:0",
        "-an",
        "-c:v",
        "libx264",
        "-preset",
        "veryfast",
        "-tune",
        "zerolatency",
        "-b:v",
        "220k",
        "-maxrate",
        "220k",
        "-bufsize",
        "440k",
        "-vf",
        "scale=320:-2",
        "-force_key_frames",
        f"expr:gte(t,n_forced*{segment_time})",
        "-f",
        "segment",
        "-segment_format",
        "mpegts",
        "-segment_time",
        str(segment_time),
        "-reset_timestamps",
        "1",
    ]
    if max_segments > 0:
        cmd.extend(["-t", str(segment_time * max_segments)])
    cmd.append(str(out_dir / "seg_%06d.ts"))

    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)
    if proc.returncode != 0:
        if proc.stderr.strip():
            sys.stderr.write(proc.stderr)
        raise SystemExit(f"ffmpeg segment generation failed with rc={proc.returncode}")
    segments = sorted(out_dir.glob("seg_*.ts"))
    return segments[:max_segments] if max_segments > 0 else segments


def load_segments(args: argparse.Namespace):
    input_path = Path(args.input)
    if input_path.is_dir():
        segments = sorted(input_path.glob("*.ts"))
        return segments[:args.max_chunks] if args.max_chunks > 0 else segments
    if not input_path.is_file():
        raise SystemExit(f"input not found: {input_path}")

    if args.segment_dir:
        return generate_segments(input_path, Path(args.segment_dir), args.segment_time, args.max_chunks, args.ffmpeg)

    temp = TemporaryDirectory(prefix="udp_mpegts_segments_")
    segments = generate_segments(input_path, Path(temp.name), args.segment_time, args.max_chunks, args.ffmpeg)
    return segments, temp


def send_segment(sock: socket.socket, args: argparse.Namespace, seq: int, ts_ms: int, path: Path, log_packet: bool) -> int:
    data = path.read_bytes()
    if not data:
        raise SystemExit(f"empty segment: {path}")
    if args.wire_fragment_size <= 0:
        raise SystemExit("--wire-fragment-size must be positive")

    frag_count = (len(data) + args.wire_fragment_size - 1) // args.wire_fragment_size
    for frag_index in range(frag_count):
        start = frag_index * args.wire_fragment_size
        fragment = data[start:start + args.wire_fragment_size]
        encoded = packet_payload(fragment)
        send_line(
            sock,
            args.host,
            args.port,
            f"SEGMENT {seq} {ts_ms} {frag_index} {frag_count} {encoded}",
            log_packet=False,
            delay=args.delay,
        )
    if log_packet:
        log(f"sent -> SEGMENT seq={seq} ts_ms={ts_ms} bytes={len(data)} fragments={frag_count} file={path.name}")
    return len(data)


def send_stream(sock: socket.socket, args: argparse.Namespace, gap: bool) -> None:
    total_bytes = 0
    sent_chunks = 0
    send_line(sock, args.host, args.port, f"STRT {args.session}")
    for chunk_index, chunk in stream_chunks(args.input, args.chunk_size, args.max_chunks):
        seq = chunk_index + 3 if gap and chunk_index > 1 else chunk_index
        ts_ms = (chunk_index - 1) * args.ts_step_ms
        encoded = packet_payload(chunk)
        send_line(
            sock,
            args.host,
            args.port,
            f"DATASEQ {seq} {ts_ms} {encoded}",
            log_packet=should_log_chunk(chunk_index, args.log_every),
            delay=args.delay,
        )
        total_bytes += len(chunk)
        sent_chunks = chunk_index

    if sent_chunks == 0:
        raise SystemExit(f"input file is empty: {args.input}")
    log(f"streamed chunks={sent_chunks} bytes={total_bytes} input={args.input}")
    send_line(sock, args.host, args.port, "END")


def send_segment_stream(sock: socket.socket, args: argparse.Namespace, gap: bool) -> None:
    loaded = load_segments(args)
    temp = None
    if isinstance(loaded, tuple):
        segments, temp = loaded
    else:
        segments = loaded
    if not segments:
        raise SystemExit(f"no MPEG-TS segments found/generated from: {args.input}")

    total_bytes = 0
    step_ms = args.ts_step_ms if args.ts_step_ms > 0 else int(args.segment_time * 1000)
    send_line(sock, args.host, args.port, f"STRT {args.session}")
    try:
        for segment_index, segment_path in enumerate(segments, start=1):
            seq = segment_index + 3 if gap and segment_index > 1 else segment_index
            ts_ms = (segment_index - 1) * step_ms
            total_bytes += send_segment(
                sock,
                args,
                seq,
                ts_ms,
                segment_path,
                log_packet=should_log_chunk(segment_index, args.log_every),
            )
        log(f"streamed segments={len(segments)} bytes={total_bytes} input={args.input}")
        send_line(sock, args.host, args.port, "END")
    finally:
        if temp is not None:
            temp.cleanup()


def send_demo(sock: socket.socket, args: argparse.Namespace) -> None:
    if args.format == "raw":
        send_stream(sock, args, gap=False)
    else:
        send_segment_stream(sock, args, gap=False)


def send_gap_demo(sock: socket.socket, args: argparse.Namespace) -> None:
    if args.format == "raw":
        send_stream(sock, args, gap=True)
    else:
        send_segment_stream(sock, args, gap=True)


def main() -> None:
    args = parse_args()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if args.shutdown:
        send_line(sock, args.host, args.port, "SHUTDOWN")
        return
    if args.mode == "demo":
        send_demo(sock, args)
        return
    if args.mode == "gap":
        send_gap_demo(sock, args)
        return
    raise SystemExit(f"unknown mode: {args.mode}")


if __name__ == "__main__":
    main()
