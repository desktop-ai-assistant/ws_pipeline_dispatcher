# 核心總覽

`stream-data-pipeline` 是 C / UNIX pipeline repo。它不接 WebSocket，也不解析 ESP32 packet。

## 輸入 Layout

```text
/tmp/stream/{session_id}/
  {session_id}.bin
  {session_id}.meta.jsonl
  .pipeline_end
```

- `.bin`：session-level binary video buffer，由上層 append DATA payload。
- `.meta.jsonl`：每個 DATA chunk 的 metadata，canonical 欄位是 `sequence`、`offset`、`length`、`ts_ms`。
- `.pipeline_end`：上層收到 `END_` 且 artifact 寫完。

## Pipeline

```text
box pipeline_dispatcher
  -> box stream_merge
  -> box log_parse --filter type=clip
  -> box clip_store
```

## 職責

- `pipeline_dispatcher`：驗證 session artifact、解析 CLI options、fork、pipe、exec 軟連結 (`box`)、waitpid、signal cleanup。
- `stream_merge`：讀 sidecar，做時間窗與 gap-aware continuity 檢查，輸出 clip metadata。
- `log_parse`：解析 raw/structured logs、過濾 JSONL records，支援 full structured log 建置與即時聚合統計 (`--sum`, `--avg`, `--min`, `--max`)。
- `clip_store`：支援資料 Zlib 無損壓縮與 Base64 編解碼，寫入純文字 structured record DB，支援 TTL、查詢、GC/compact。

## Non-Goals

- WebSocket server。
- ESP32 packet parser。
- UDP/RTP socket server（只用 demo scripts 展示 contract）。
- 真正切出 playable MP4/MP3 clip。

## 後續工作

- demo evidence 與 final report 整理。
- 若需要正式 media output，新增 downstream `clip_extract` / `clip_mux`，不要塞進 `stream_merge` 或 `pipeline_dispatcher`。
