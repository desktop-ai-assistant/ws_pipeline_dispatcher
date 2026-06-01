import json, os, random, sys

def generate_dataset(session_id, base_dir, mode="medium"):
    os.makedirs(base_dir, exist_ok=True)
    bin_path = os.path.join(base_dir, f"{session_id}.bin")
    meta_path = os.path.join(base_dir, f"{session_id}.meta.jsonl")

    chunk_count = 100 if mode == "small" else 10000
    if mode == "malformed": chunk_count = 500

    current_offset = 0
    with open(bin_path, "wb") as f_bin, open(meta_path, "w") as f_meta:
        for i in range(chunk_count):
            length = 4096

            # Malformed mode: intentionally skip seq at record 200 to trigger continuity break
            seq = i + 1
            if mode == "malformed" and i == 200:
                seq += 5

            data = os.urandom(length)
            f_bin.write(data)

            meta = {
                "kind": "data",
                "sequence": seq,
                "offset": current_offset,
                "length": length,
                "ts_ms": 1000 + (i * 100)
            }
            f_meta.write(json.dumps(meta) + "\n")
            current_offset += length

    with open(os.path.join(base_dir, ".pipeline_end"), "w") as f:
        f.write("done")
    print(f"[{mode.upper()}] Dataset '{session_id}' generated: {chunk_count} records.")


def generate_jsonl_dataset(base_dir, count=50000):
    os.makedirs(base_dir, exist_ok=True)
    path = os.path.join(base_dir, "bench_jsonl.jsonl")
    types = ['clip', 'event', 'heartbeat', 'error', 'debug']
    with open(path, 'w') as f:
        for i in range(count):
            t = types[i % len(types)]
            record = {
                "type": t,
                "session_id": "bench",
                "ts": i,
                "id": i,
                "msg": "synthetic record {}".format(i)
            }
            f.write(json.dumps(record, separators=(',', ':')) + '\n')
    print("[JSONL] Generated {} records ({} clip) -> {}".format(count, count // len(types), path))


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "medium"
    if mode == "jsonl":
        generate_jsonl_dataset("test_env")
    else:
        generate_dataset("bench_{}".format(mode), "test_env", mode)
