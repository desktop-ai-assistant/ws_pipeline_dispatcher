# clip_store

`clip_store` 是 pipeline 終端的 file-backed structured record store。它從 stdin 接收 JSON Lines，用 `session_id:ts` 建立索引，將完整 record 進行 **Zlib 無損壓縮與 Base64 編碼**後寫入 append-only 純文字 DB，並提供查詢、TTL、delete tombstone 與 compact/GC。

## DB Format

```text
key<TAB>Z:base64_compressed_value<TAB>expire_at<NEWLINE>
```

- `key`：預設為 `session_id:ts`。
- `value`：完整 JSON record。儲存時會加上 `Z:` 前綴，代表它被 `miniz` (zlib) 壓縮並轉換為 Base64 格式。讀取時會自動反向解碼與解壓縮。
- `expire_at=0`：永不過期。

## Commands

```text
clip_store --db <path> --ttl <seconds>
clip_store --db <path> --set <key=value>
clip_store --db <path> --get <key>
clip_store --db <path> --list
clip_store --db <path> --prefix <session_id:>
clip_store --db <path> --delete <key>
clip_store --db <path> --compact
clip_store --db <path> --gc
```

## 行為

- 預設 append mode 從 stdin 讀取 JSON Lines，要求 top-level `session_id` 與 `ts` 欄位。
- append mode 會保存完整 JSON record；`path`、`offset`、`length`、`complete` 等欄位可供後續 extraction/replay 使用。
- `--set` append 一筆 key-value row。
- `--get` 只回傳 latest live record。
- `--list` 與 `--prefix` 只顯示 live records。
- `--delete` append tombstone row（空 value）。
- `--compact` / `--gc` 透過 temp file + rename 重寫 DB。
- compaction 會丟棄 expired rows、tombstones、以及被覆蓋的舊 rows。
- query 與 compaction 都會重建 in-memory hash index，保留每個 key 的 latest state。
- write path 使用 file locking，避免並發寫入破壞 DB。

## Pipeline 用法

```text
box stream_merge ... | box log_parse --filter type=clip | box clip_store --db clips.db --ttl 300
```

`clip_store` 儲存 structured metadata record，不負責讀取或轉換 `.bin` media bytes。若 record 內含 `path`、`offset`、`length`，下游 extractor 可依這些欄位切出實體 clip。
