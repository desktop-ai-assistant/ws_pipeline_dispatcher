#!/usr/bin/env python3
import argparse
import base64
import json
import os
import pathlib
import socket
import subprocess
import sys


def parse_args() -> argparse.Namespace:
    root_dir = os.environ.get("ROOT_DIR", "/tmp/udp_demo")
    parser = argparse.ArgumentParser(description="Run a tiny UDP ingestor demo for pipeline_dispatcher.")
    parser.add_argument("--host", default=os.environ.get("HOST", "0.0.0.0"), help="bind address")
    parser.add_argument("--port", type=int, default=int(os.environ.get("PORT", "10005")), help="UDP port")
    parser.add_argument("--root-dir", default=root_dir, help="session artifact root")
    parser.add_argument("--db", default=os.environ.get("DB_PATH", str(pathlib.Path(root_dir) / "clips.db")), help="clip_store database path")
    parser.add_argument("--ttl", default=os.environ.get("CLIP_TTL", "300"), help="TTL passed to pipeline_dispatcher")
    parser.add_argument("--dispatcher", default=os.environ.get("PIPELINE_DISPATCHER", str(pathlib.Path.cwd() / ".build" / "pipeline_dispatcher")), help="pipeline_dispatcher binary path")
    parser.add_argument("--log-every", type=int, default=int(os.environ.get("LOG_EVERY", "1000")), help="log every N DATASEQ packets after the first few")
    return parser.parse_args()


def log(message: str) -> None:
    print(f"[udp-server] {message}", file=sys.stderr, flush=True)


def ensure_dispatcher(path: str) -> None:
    if not os.path.exists(path):
        raise SystemExit(f"dispatcher not found: {path}")


def start_session(session_id: str, root_dir: pathlib.Path, dispatcher: str, ttl: str, db_path: str):
    session_dir = root_dir / session_id
    session_dir.mkdir(parents=True, exist_ok=True)
    bin_path = session_dir / f"{session_id}.bin"
    meta_path = session_dir / f"{session_id}.meta.jsonl"
    bin_fp = open(bin_path, "wb", buffering=0)
    meta_fp = open(meta_path, "w", encoding="utf-8")
    proc = subprocess.Popen(
        [dispatcher, "--ttl", ttl, session_id, str(session_dir), db_path],
        stdout=subprocess.DEVNULL,
    )
    log(f"started session={session_id} dispatcher_pid={proc.pid}")
    return {
        "id": session_id,
        "dir": session_dir,
        "bin_fp": bin_fp,
        "meta_fp": meta_fp,
        "proc": proc,
        "offset": 0,
        "chunks": 0,
        "bytes": 0,
        "segments": {},
    }


def should_log_chunk(count: int, log_every: int) -> bool:
    return count <= 3 or (log_every > 0 and count % log_every == 0)


def write_chunk(state, seq: int, ts_ms: int, payload_b64: str, log_every: int) -> None:
    payload = base64.b64decode(payload_b64)
    write_payload(state, seq, ts_ms, payload, log_every, media_format="raw", segment_aligned=False)


def write_payload(state, seq: int, ts_ms: int, payload: bytes, log_every: int, media_format: str, segment_aligned: bool) -> None:
    offset = state["offset"]
    state["bin_fp"].write(payload)
    record = {
        "kind": "data",
        "sequence": seq,
        "offset": offset,
        "length": len(payload),
        "ts_ms": ts_ms,
    }
    if media_format:
        record["format"] = media_format
    if segment_aligned:
        record["segment_aligned"] = True
    state["meta_fp"].write(json.dumps(record, separators=(",", ":")) + "\n")
    state["meta_fp"].flush()
    state["offset"] += len(payload)
    state["chunks"] += 1
    state["bytes"] += len(payload)
    if should_log_chunk(state["chunks"], log_every):
        unit = "segment" if segment_aligned else "chunk"
        log(f"session={state['id']} {unit}={state['chunks']} seq={seq} ts_ms={ts_ms} bytes={len(payload)} total_bytes={state['bytes']}")


def write_segment_fragment(state, seq: int, ts_ms: int, frag_index: int, frag_count: int, payload_b64: str, log_every: int) -> None:
    if frag_count <= 0 or frag_index < 0 or frag_index >= frag_count:
        log("invalid SEGMENT fragment index/count")
        return
    payload = base64.b64decode(payload_b64)
    key = (seq, ts_ms)
    entry = state["segments"].setdefault(key, {"count": frag_count, "parts": {}})
    if entry["count"] != frag_count:
        log(f"SEGMENT fragment count changed seq={seq}")
        state["segments"].pop(key, None)
        return
    entry["parts"][frag_index] = payload
    if len(entry["parts"]) != frag_count:
        return

    segment = b"".join(entry["parts"][idx] for idx in range(frag_count))
    state["segments"].pop(key, None)
    write_payload(state, seq, ts_ms, segment, log_every, media_format="mpegts", segment_aligned=True)


def end_session(state) -> None:
    sentinel = state["dir"] / ".pipeline_end"
    sentinel.touch()
    state["meta_fp"].close()
    state["bin_fp"].close()
    rc = state["proc"].wait(timeout=10)
    log(f"ended session={state['id']} chunks={state['chunks']} bytes={state['bytes']} dispatcher_rc={rc}")


def main() -> None:
    args = parse_args()
    root_dir = pathlib.Path(args.root_dir)
    root_dir.mkdir(parents=True, exist_ok=True)
    ensure_dispatcher(args.dispatcher)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
    sock.bind((args.host, args.port))
    log(f"listening on udp://{args.host}:{args.port}")

    current = None
    while True:
        data, addr = sock.recvfrom(65535)
        line = data.decode("utf-8").strip()
        if not line:
            continue
        parts = line.split(" ", 5)
        cmd = parts[0]
        if cmd not in ("DATASEQ", "SEGMENT"):
            log(f"recv from {addr[0]}:{addr[1]} -> {line}")

        if cmd == "SHUTDOWN":
            if current is not None:
                end_session(current)
            log("shutdown requested")
            return

        if cmd == "STRT":
            if len(parts) != 2:
                log("invalid STRT packet")
                continue
            if current is not None:
                end_session(current)
            current = start_session(parts[1], root_dir, args.dispatcher, args.ttl, args.db)
            continue

        if cmd == "END":
            if current is None:
                log("END ignored; no active session")
                continue
            end_session(current)
            current = None
            continue

        if cmd == "DATASEQ":
            if current is None:
                log("DATASEQ ignored; no active session")
                continue
            if len(parts) != 4:
                log("invalid DATASEQ packet")
                continue
            try:
                seq = int(parts[1])
                ts_ms = int(parts[2])
            except ValueError:
                log("invalid numeric field in DATASEQ")
                continue
            write_chunk(current, seq, ts_ms, parts[3], args.log_every)
            continue

        if cmd == "SEGMENT":
            if current is None:
                log("SEGMENT ignored; no active session")
                continue
            if len(parts) != 6:
                log("invalid SEGMENT packet")
                continue
            try:
                seq = int(parts[1])
                ts_ms = int(parts[2])
                frag_index = int(parts[3])
                frag_count = int(parts[4])
            except ValueError:
                log("invalid numeric field in SEGMENT")
                continue
            write_segment_fragment(current, seq, ts_ms, frag_index, frag_count, parts[5], args.log_every)
            continue

        log(f"unknown command: {cmd}")


if __name__ == "__main__":
    main()
