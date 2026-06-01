# pipeline_dispatcher

`pipeline_dispatcher` 是本 repo 的 process orchestrator。它不處理 UDP/RTP、不解析 binary payload，也不直接操作 clip JSON；它只負責驗證 session artifact，並透過 **BusyBox 單一執行檔架構 (`box`)** 建立三段 UNIX pipeline：

```text
box stream_merge --clip-secs N --idle-secs M <session_id> <src_dir>
  | box log_parse --filter <expr>
  | box clip_store --db <db_path> --ttl <seconds>
```

## CLI

```text
pipeline_dispatcher [OPTIONS] <session_id> <src_dir> <db_path>
```

Options:

```text
--ttl <seconds>       傳給 clip_store 的 TTL，預設 300
--clip-secs <n>       傳給 stream_merge 的 clip 時間窗，預設 5
--idle-secs <n>       傳給 stream_merge 的 idle timeout，預設 2
--filter <expr>       傳給 log_parse 的 filter，預設 type=clip
-h, --help            顯示說明並結束
```

## 責任邊界

`pipeline_dispatcher` 負責：

- 驗證 `session_id`、`src_dir`、`db_path` 與數字參數。
- 從自身 executable 位置解析 sibling applets (透過 `box` 軟連結)：`stream_merge`、`log_parse`、`clip_store`。
- 建立兩條 pipe。
- `fork()` / `execv()` 三個 child process。
- 關閉 parent/child 中不需要的 pipe fd。
- 等待 child processes 並整合 exit code。
- 收到 `SIGINT` / `SIGTERM` 時清理已啟動的 children。

`pipeline_dispatcher` 不負責：

- UDP/RTP socket 接收。
- 上游 packet reorder 或 session 邊界判斷。
- `.bin` 轉 MP4/MP3。
- clip byte-range 的實體抽取。

## 模組結構

```text
applets/pipeline_dispatcher/
  pipeline_dispatcher.c   main flow
  pd_config.*             CLI parsing、驗證與 applet path resolution
  pd_pipeline.*           pipe topology 與 argv wiring
  pd_spawn.*              fork/exec/wait/kill child processes
  pd_signal.*             SIGINT/SIGTERM interrupt flag
  pd_exit.h               shell-visible exit codes
```

## Exit Codes

```text
0    成功，所有 children exit 0
1    setup / validation failure
2    bad arguments
3    任一 child 非 0 結束或被 signal 結束
130  dispatcher 收到 SIGINT / SIGTERM 並清理 children
```

## 與上游 UDP demo 的關係

`scripts/example/full-run/udp_stream_data_server.sh` 是 demo 用的上游 ingestor。它接收 UDP datagrams，落地 `{session_id}.bin` 與 `{session_id}.meta.jsonl`，然後在 session 開始後啟動 `pipeline_dispatcher`。

這表示 dispatcher 的責任是 process orchestration，而不是 socket server。正式產品中，上游可以替換成 RTP receiver、WebSocket host 或其他 ingestor，只要產出的 filesystem contract 相同即可。
