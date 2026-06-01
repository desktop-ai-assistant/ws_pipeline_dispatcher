# stream-data-pipeline

`stream-data-pipeline` 是一組以 C 實作的 UNIX pipeline applets，對應 UNIX 系統程式設計期末專題選項 B「BusyBox 工具擴充」中的方向三「Embedded Data Pipeline」。

本 repo 把上層落地的 append-only stream 轉成可被 UNIX pipe 組合、過濾、儲存的資料處理管線。

## 專案主軸

系統分成兩層：

- `edge-ws-host` 或 UDP Server 等 Ingestor：接收連線或封包，將每個資料 payload append 到 session-level `{session_id}.bin` buffer，將 offset metadata 落到 sidecar，並在 session 開始時啟動 C pipeline。
- `stream-data-pipeline` (`pipeline_dispatcher`)：讀取上層落地的 session artifact，切出 structured clip metadata，過濾 clip event，壓縮並寫入 file-backed index。

核心設計是把複雜串流處理拆成三個小工具，並將它們**封裝為單一的 BusyBox 架構執行檔 (`box`)**：

```text
box stream_merge | box log_parse --filter type=clip | box clip_store
```

每個 applet 只做一件事，stdout 只傳資料，stderr 只寫診斷訊息。這讓整體行為符合 UNIX pipeline 的組合方式，也能在資源受限環境中以小型 C binary 運作。

## 作業方向對應

| 作業 B + 方向三要求 | 本 repo 對應 |
| --- | --- |
| 使用 C 語言實作 3 個新的 applet | `stream_merge`、`log_parse`、`clip_store` |
| 將工具編譯為單一執行檔 (BusyBox 架構) | 實作 `applets/main.c` 總進入點，編譯出單一 `.build/box` 二進位檔，並建立軟連結 |
| 結構化日誌解析器與即時聚合統計 | `log_parse --regex ... --fields ... --format json\|csv`，支援 `--build-full-log` 與 `--sum`, `--avg`, `--max`, `--min` 即時聚合 |
| GNU / Toybox 相容性 | `log_parse` 支援 `-E` 參數對標 `grep -E` |
| 串流資料過濾與轉換工具 | `stream_merge` 讀取 growing file，`log_parse --filter key=value` 過濾 records |
| 輕量級資料儲存引擎與資料壓縮 | `clip_store` 寫入 file-backed structured record DB，引入 `miniz` 支援 zlib 無損壓縮，並自動 Base64 編碼，支援 TTL、查詢與 GC |
| 三個工具可透過 UNIX pipe 組成完整管線 | `pipeline_dispatcher` 建立 `stream_merge -> log_parse -> clip_store` |
| 提取共用邏輯為內部函式庫 | `libpipeline`、`stream_logger`、`miniz`、`base64` |
| 遵循 stdout/stderr 與 CLI 慣例 | applet stdout 保持資料流，diagnostic logs 走 stderr |
| 效能基準測試與 GNU 對標 | `scripts/benchmark/run_all.sh` 實證 JSON 解析快於 `jq`，聚合統計效能達 GNU `awk` 50% 標準內 |

完整對照表見 [`.docs/core/compliance.md`](.docs/core/compliance.md)。

## Pipeline 架構

```text
ESP32 Video Data
  -> edge-ws-host
  -> /tmp/stream/{session_id}/{session_id}.bin
  -> /tmp/stream/{session_id}/{session_id}.meta.jsonl
  -> pipeline_dispatcher
       box stream_merge stdout -> box log_parse stdout -> box clip_store
  -> /tmp/clips.db
```

`pipeline_dispatcher` 是 C entry point，負責建立 process pipeline：

- 用 `pipe()` 建立 applet 間的資料通道。
- 用 `fork()` 建立 child processes。
- 用 `execv()` 執行三個 applet。
- 用 `waitpid()` 回收 child 狀態並回報整體 exit code。

跨 repo 的啟動時機、檔案 layout 與 packet contract 以 Linear integration docs 為準；repo 內部實作細節則記錄在 `.docs/`。

## Applets

### `pipeline_dispatcher`

建立三段 UNIX pipeline，不直接處理 clip JSON：

```text
pipeline_dispatcher [OPTIONS] <session_id> <src_dir> <db_path>
```

### `stream_merge`

正確 contract 下會讀取 `{src_dir}/{session_id}.bin` 與 `{src_dir}/{session_id}.meta.jsonl`。上層目前以持久 WebSocket/TCP 連線接收 ESP32 資料；一個 session 會在 `STRT` 與 `END_` 之間收到很多個 `DATA` messages。每個 `DATA` 只是一小段影片資料，會被 append 到同一個 `.bin`，因此 `.bin` 是供下層操作的 session-level binary buffer。`stream_merge` 依 sidecar 從這個 buffer 抽出 5s 等時間窗對應的 byte range，並輸出 clip metadata。

### `log_parse`

stdin -> stdout 的 structured record processor，支援三種用途：

- 基本需求：regex-based parsing、輸出 JSON 或 CSV。
- Filter 功能：讀取 JSON Lines，使用 `--filter key=value` 保留指定 records。
- 聚合統計功能：即時對日誌的數值欄位做計算，支援 `--sum`, `--avg`, `--max`, `--min`。

### `clip_store`

pipeline 終端的 file-backed structured record DB。從 stdin 讀取 JSON Lines，用 `session_id:ts` 作為 key，完整 JSON record 作為 value，並在寫入時使用 `miniz` 進行 Zlib 壓縮及 Base64 編碼，寫入純文字 DB，並提供查詢、TTL 與 GC 行為。

## 系統程式設計重點

本 repo 的技術重點集中在 UNIX 系統程式設計，而不是 Web framework：

- Process management：`fork()`、`execv()`、`waitpid()`。
- IPC：`pipe()`、stdin/stdout chaining。
- Filesystem streaming：append-only `.bin`、`.meta.jsonl` sidecar、sentinel file、tail-read offset。
- Single Executable (BusyBox)：主程式 dispatcher 透過軟連結或 `argv[1]` 機制呼叫對應 applet。
- File-backed storage & Compression：`open()`、`flock()`、append-only index、GC rewrite 方向，整合 `zlib` (miniz) 進行記憶體中字串壓縮。
- Error handling：exit code propagation、child process failure handling。
- Stream discipline：stdout 只放 structured data，stderr 只放 diagnostic logs。

## 編譯與測試

```bash
make              # 編譯並產生單一執行檔 .build/box 及 applet 軟連結
make test         # 執行 lib 與 applets C unit tests 與整合 shell tests
bash scripts/benchmark/run_all.sh # 執行與 jq, awk 的吞吐量效能對比基準測試
make smoke        # 執行 end-to-end skeleton smoke test
make clean        # 移除 build artifacts
```

安裝後可透過 `man stream_merge`、`man log_parse`、`man clip_store` 查閱文件；
未安裝時可直接用 `man ./man/stream_merge.1` 預覽。

目前測試涵蓋：

- `libpipeline` inotify、buffer、sentinel helpers。
- `stream_logger` stderr-only logging。
- `log_parse` regex parsing、JSON/CSV output、filter 行為。
- `stream_merge` `.meta.jsonl` sidecar drain、5s window、continuity 與 sentinel 行為。
- `clip_store` append/get/TTL/GC/concurrent writes。
- `pipeline_dispatcher` process orchestration 與 end-to-end DB 寫入。

## 快速 Demo

最小 end-to-end 使用方式：

```bash
make
rm -rf /tmp/stream/demo /tmp/clips.db
mkdir -p /tmp/stream/demo
: > /tmp/stream/demo/demo.bin
: > /tmp/stream/demo/demo.meta.jsonl
./.build/pipeline_dispatcher --ttl 300 demo /tmp/stream/demo /tmp/clips.db &
pid=$!
printf '\x00\x01\x02\x03' >> /tmp/stream/demo/demo.bin
printf '%s\n' '{"kind":"data","sequence":1,"offset":0,"length":4,"ts_ms":1000}' >> /tmp/stream/demo/demo.meta.jsonl
touch /tmp/stream/demo/.pipeline_end
wait "$pid"
cat /tmp/clips.db
```

完整 demo 會在 v2.2 的 benchmark/demo evidence 中補成可重跑腳本，涵蓋多筆 stream、malformed input、TTL/GC 與 failure behavior。

### UDP Stream Demo Scripts

為了把上游 ingestor 與 `pipeline_dispatcher` 的責任邊界具體化，`scripts/example/full-run/` 內提供 UDP demo：

- `scripts/example/full-run/udp_stream_data_server.sh`
  - 模擬上游 UDP ingestor
  - 接收 `STRT` / `SEGMENT` / `DATASEQ` / `END` datagrams
  - `SEGMENT` 允許一個 MPEG-TS segment 拆成多個 UDP datagrams 傳輸；server 收齊後才 append 一次 `{session_id}.bin` 並寫一行 `{session_id}.meta.jsonl`
  - 在 `STRT` 後立即啟動 `pipeline_dispatcher`
- `scripts/example/full-run/udp_stream_data_client.sh`
  - 預設用 `ffmpeg` 將 `scripts/example/full-run/videoplayback.mp4` 轉成 MPEG-TS segments
  - 每個完整 `.ts` segment 會成為 `.bin` 中的一次 append；`.meta.jsonl` 一行對應一個 segment append
  - 預設 `--max-chunks 0`，表示持續傳送完整 input；可用 `--max-chunks N` 縮短 smoke test
  - `--wire-fragment-size 32768` 只控制 UDP datagram 大小，不是 media clip boundary
  - 傳輸結束後預設會呼叫 `extract_udp_clips.sh`，從 `clips.db` 切出 raw clips 並嘗試 remux 成 `.mp4`
  - 傳送 normal demo 或 gap demo datagrams

最小示例：

```bash
make
scripts/example/full-run/udp_stream_data_server.sh --root-dir /tmp/udp_demo --db /tmp/udp_demo/clips.db &
server_pid=$!
scripts/example/full-run/udp_stream_data_client.sh --mode demo --session demo_udp
scripts/example/full-run/udp_stream_data_client.sh --shutdown
wait "$server_pid"
cat /tmp/udp_demo/clips.db
```

若要一鍵跑完整 demo，包含事前清除 `/tmp/udp_demo`、啟動 server、持續傳送完整 input、auto extraction 與 shutdown：

```bash
scripts/example/full-run/full-run.sh
```

可用環境變數調整，例如：

```bash
MAX_CHUNKS=20 MODE=gap scripts/example/full-run/full-run.sh
```

預設會將整個 `videoplayback.mp4` 轉成 MPEG-TS segments 後傳送，以展示 pipeline 可以同步處理持續輸入；若 demo 時間有限，可設定 `MAX_CHUNKS=N` 或 `--max-chunks N` 只傳前 N 段。`--mode gap` 會刻意讓 segment sequence 跳號，`stream_merge` 會在 gap 處結束目前 clip 並從下一段重新開始，因此可用來展示 broken stream 的 partial/restart 行為。

client 傳送 `END` 後會自動執行 extraction。預設讀取 `/tmp/udp_demo/clips.db`，輸出到 `/tmp/udp_demo/extracted`；若 demo 使用不同路徑，可指定：

```bash
scripts/example/full-run/udp_stream_data_client.sh \
  --session demo_udp \
  --extract-db /path/to/clips.db \
  --extract-out-dir /path/to/extracted
```

若只想傳送、不想自動切檔，可加 `--no-extract`。

一個 session 的 artifact 仍維持三個檔案：

```text
/tmp/udp_demo/demo_udp/demo_udp.bin        # append-only media segment buffer
/tmp/udp_demo/demo_udp/demo_udp.meta.jsonl # one row per segment append
/tmp/udp_demo/demo_udp/.pipeline_end       # session completion marker
```

`demo_udp.bin` 的內容是多個完整 MPEG-TS segments 串接：

```text
demo_udp.bin = segment_1.ts + segment_2.ts + segment_3.ts + ...
```

`stream_merge` 不解析影音格式；它只檢查 `sequence` 與 `offset` 是否連續，並用 `ts_ms` 的 window 聚合完整 segments。若目標 clip 是 5 秒但 segment 是 3 秒，clip 會對齊 segment boundary，例如輸出約 6 秒，而不是切斷單一 segment。

`clips.db` 是 clip-level index，不直接存 media bytes。`extract_udp_clips.sh` 會用 `clip_store --prefix` / `--list` 讀出 clip objects，依 `session_id`、source path 與 `offset` 排序，再依每筆 record 的 `path` / `offset` / `length` 切出 raw binary：

```text
/tmp/udp_demo/extracted/raw/0001_demo_udp_...bin
/tmp/udp_demo/extracted/manifest.jsonl
```

若系統有 `ffmpeg`，script 也會嘗試把切出的 raw bytes remux 成 `.mp4`，並將同一 session 的 clips 依序串成：

```text
/tmp/udp_demo/extracted/raw/demo_udp_ordered.bin
/tmp/udp_demo/extracted/media/demo_udp_ordered.mp4
```

因為 demo input 已轉為 segment-aligned MPEG-TS，`extract_udp_clips.sh` 切出的 raw clip 會由一個或多個完整 `.ts` segments 組成；若系統有 `ffmpeg`，script 會嘗試 remux 成 `.mp4`。

這些 script 是 demo / contract 工具，不是正式 applet；它們的目的是說明：

- 上游 socket ingestor 負責落地 `.bin` 與 `.meta.jsonl`
- `pipeline_dispatcher` 負責啟動 `stream_merge -> log_parse -> clip_store`
- `clips.db` 保存 Agent 可查詢的 clip objects；extract script 才依 clip index 產生實體影音片段

## 目錄結構

```text
.
|-- applets/
|   |-- main.c                      # BusyBox 單一執行檔入口，透過 argv[0] 或 argv[1] 分派 applet
|   |-- pipeline_dispatcher/        # fork + pipe + exec orchestration
|   |-- stream_merge/               # sidecar-driven clip metadata emitter
|   |-- log_parse/                  # regex parser, JSON/CSV formatter, record filter
|   `-- clip_store/                 # file-backed clip index with zlib compression
|-- lib/
|   |-- libpipeline.{h,c}           # inotify, monotonic time, buffer, sentinel helpers
|   |-- stream_logger.{h,c}         # stderr-only diagnostic logger
|   |-- dynamic_buffer.{h,c}        # growable byte buffer
|   |-- jsonl_codec.{h,c}           # JSON Lines encode/decode helpers
|   |-- base64.{h,c}                # Base64 encode/decode (used by clip_store compression)
|-- man/
|   |-- stream_merge.1              # man page: stream_merge
|   |-- log_parse.1                 # man page: log_parse
|   |-- clip_store.1                # man page: clip_store
|   `-- pipeline_dispatcher.1       # man page: pipeline_dispatcher
|-- scripts/
|   |-- benchmark/
|   |   `-- run_all.sh              # 與 jq, awk 的吞吐量效能對比基準測試
|   `-- example/
|       |-- applets/                # 單一 applet demo scripts
|       `-- full-run/               # UDP/full pipeline demo scripts 與本地 media input
|-- tests/
|   |-- lib/                        # lib 層 C unit tests
|   |-- applets/                    # 各 applet C unit tests
|   |   |-- clip_store/
|   |   |-- log_parse/
|   |   |-- pipeline_dispatcher/
|   |   `-- stream_merge/
|   |-- test_clip_store.sh          # clip_store shell integration test
|   |-- test_log_parse.sh           # log_parse shell integration test
|   |-- test_pipeline_dispatcher.sh # pipeline_dispatcher shell integration test
|   `-- test_stream_merge.sh        # stream_merge shell integration test
|-- .third-party/
|   |-- cJSON/                      # JSON 解析函式庫（git submodule）
|   `-- miniz/                      # zlib-compatible 壓縮函式庫（git submodule）
|-- .docs/                          # repo-local implementation and design docs
|   |-- core/                       # project overview and compliance summary
|   `-- applets/                    # per-applet behavior docs
`-- Makefile
```

## 目前狀態

目前 repo 已完成可測試的 pipeline baseline：

- `pipeline_dispatcher` 可驗證 session artifact、解析 CLI options，並建立 `stream_merge -> log_parse -> clip_store` process pipeline。
- `stream_merge` 可讀取 `.meta.jsonl` sidecar、驗證 session `.bin` 存在、做時間窗與 continuity 檢查，並輸出 clip byte-range metadata JSON Lines；CRC、events merge 與實體 mp4 clip extraction 留作 future work。
- `log_parse` 可做 regex parsing、JSON/CSV output、JSONL filter 與 full structured log 建置。
- `clip_store` 可寫入 file-backed structured record DB，並支援查詢、TTL、GC。
- `libpipeline` 與 `stream_logger` 提供 applet 共用低階 helper。


## 文件

- Repo-local docs index：[`./.docs/Home.md`](.docs/Home.md)
- Core docs：[`./.docs/core/`](.docs/core/)
- Applet docs：[`./.docs/applets/`](.docs/applets/)
- Assignment compliance summary：[`./.docs/core/compliance.md`](.docs/core/compliance.md)
- Internal overview：[`./.docs/core/overview.md`](.docs/core/overview.md)
- Man pages：[`man/stream_merge.1`](man/stream_merge.1)、[`man/log_parse.1`](man/log_parse.1)、[`man/clip_store.1`](man/clip_store.1)
- Toybox / GNU 相容性矩陣：[`.docs/core/compatibility.md`](.docs/core/compatibility.md)
- Cross-repo integration contract：Linear integration docs

若 Linear integration docs 與 repo-local docs 衝突，以 Linear 作為跨 repo contract 的 source of truth；repo `.docs/` 則描述本 repo 的實作細節、測試與設計限制。
