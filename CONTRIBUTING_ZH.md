# stream-data-pipeline 貢獻指南

感謝你協助改進 `stream-data-pipeline`。

本專案是 **Embedded Stream Data Pipeline** 期末專題的一部分，目標是用 C 語言實作 BusyBox-style 工具集，將嵌入式裝置產生的 append-only session artifact 轉成結構化 clip metadata、可過濾的 JSON Lines，以及輕量級 file-backed clip index。

核心流程如下：

```text
ESP32 / UDP-RTP-like stream / edge ingestor
  -> session artifact on disk
  -> pipeline_dispatcher
  -> stream_merge | log_parse --filter type=clip | clip_store
  -> clips.db
```

在建立 issue、pull request、benchmark 結果或修改文件前，請先閱讀本指南。

---

## 目錄

1. [專案理念](#1-專案理念)
2. [專案範圍與 Session Artifact Contract](#2-專案範圍與-session-artifact-contract)
3. [歡迎的貢獻類型](#3-歡迎的貢獻類型)
4. [架構與 Applet 責任邊界](#4-架構與-applet-責任邊界)
5. [行為契約](#5-行為契約)
6. [開發環境](#6-開發環境)
7. [程式碼風格](#7-程式碼風格)
8. [測試要求](#8-測試要求)
9. [Benchmark 與效能規則](#9-benchmark-與效能規則)
10. [文件維護規則](#10-文件維護規則)
11. [Git 工作流程](#11-git-工作流程)
12. [Commit 訊息格式](#12-commit-訊息格式)
13. [Pull Request 要求](#13-pull-request-要求)
14. [Issue 回報與故障排除](#14-issue-回報與故障排除)
15. [相容性與目前限制](#15-相容性與目前限制)
16. [提交前檢查清單](#16-提交前檢查清單)
17. [問題與資安回報](#17-問題與資安回報)

---

## 1. 專案理念

`stream-data-pipeline` 遵循 UNIX 系統程式設計精神：

- **單一責任** — 每個 applet 只做一件清楚的事情。
- **組合優於單體** — 工具透過 pipe 串接，而不是合併成一個巨大程式。
- **Stream discipline** — `stdout` 只輸出資料；`stderr` 只輸出診斷訊息。
- **File-backed contract** — session data 透過 append-only 檔案與 metadata sidecar 交換。
- **最小依賴** — 核心以 C11/POSIX 為主，適合資源受限的 embedded Linux-like 環境。
- **可觀察行為** — CLI 行為、exit code、測試與文件都應讓變更容易驗證。

不要加入會讓某個 applet 承擔其他 applet 責任的功能。若不確定，請優先維持 pipeline 小型、明確、容易測試。

---

## 2. 專案範圍與 Session Artifact Contract

本 repository 是**下游 UNIX pipeline 層**。它不是 WebSocket server、UDP/RTP packet receiver、ESP32 parser，也不是影音轉檔器。

上層系統（例如 `edge-ws-host` 或 UDP demo server）負責接收封包並將 session artifact 寫到磁碟。本 repository 的工作從 session artifact 已存在後開始。

預期 session layout：

```text
/tmp/stream/{session_id}/
  {session_id}.bin
  {session_id}.meta.jsonl
  .pipeline_end
```

Artifact contract：

| 檔案 | 意義 | 貢獻規則 |
| --- | --- | --- |
| `{session_id}.bin` | 整個 session 的 append-only binary payload buffer | ingestion 過程中不要重寫前面已寫入的 bytes。 |
| `{session_id}.meta.jsonl` | 包含 sequence、offset、length、timestamp、optional events 的 sidecar metadata index | clip boundary 應以 metadata 為主要依據。 |
| `.pipeline_end` | 表示 session 已完成的 sentinel 檔 | 使用此**精確拼法**，不要引入 `.pipline_end` 或其他變體。 |

重要假設：

- 資料可能來自 UDP/RTP-like transport，因此 chunk loss、gap、duplicate、late arrival 都可能發生。
- `.bin` 存的是實際 append 的 raw bytes，不是索引。
- `.meta.jsonl` 是 byte-range index，讓 pipeline 決定 `.bin` 的哪一段屬於哪個 clip。
- clip index 不等於實體影片檔。`clips.db` 儲存 clip records；extract/remux 屬於 demo script 或未來 media tooling 的責任。

---

## 3. 歡迎的貢獻類型

### 功能與 applet 改進

- 在維持責任邊界的前提下，改進 `pipeline_dispatcher`、`stream_merge`、`log_parse` 或 `clip_store`。
- 新增範圍清楚的 CLI option，並同步補測試與 man page。
- 改善邊界情況：malformed metadata、EOF handling、gap handling、TTL behavior、compaction safety。

### 文件與範例

- 改進 `README.md`、`man/*.1`、`.docs/` 與 example scripts。
- 補充架構說明、sequence diagram 或 demo 操作方式。
- 修正 code、documentation、benchmark notes 與簡報素材之間的術語不一致。

### Bug 與可靠性

- 修正 parsing、filtering、process lifecycle、file-locking 或 storage 相關 bug。
- 改善 diagnostics，但不能污染 `stdout`。
- 為曾經壞掉的行為加入 regression tests。

### 效能與 embedded constraints

- 降低記憶體使用量與不必要的 allocation。
- 改善 streaming throughput。
- 提升 benchmark 可重現性。
- 與 GNU/Toybox-style tools 比較時，使用正確 benchmark 分類，並公平呈現結果。

### 測試

- 為 `lib/` 與 applet internals 補 unit tests。
- 為 CLI 行為補 shell integration tests。
- 為 dispatcher pipeline 補 end-to-end smoke tests。

常見 GitHub labels：

| Label | 意義 |
| --- | --- |
| `good first issue` | 適合初次貢獻者的小任務 |
| `help wanted` | Maintainer 希望外部協助 |
| `bug` | 錯誤行為 |
| `documentation` | 文件、範例、圖表、man pages |
| `enhancement` | 功能或改進需求 |
| `performance` | throughput、memory 或 benchmark 相關工作 |
| `question` | 設計討論 |

---

## 4. 架構與 Applet 責任邊界

完整流程如下：

```text
ESP32 / stream source
  -> edge-ws-host or UDP demo ingestor
  -> /tmp/stream/{session_id}/{session_id}.bin
  -> /tmp/stream/{session_id}/{session_id}.meta.jsonl
  -> /tmp/stream/{session_id}/.pipeline_end
  -> pipeline_dispatcher
       stream_merge
         | log_parse --filter type=clip
         | clip_store --db /tmp/clips.db
  -> /tmp/clips.db
```

每個 applet 都應保持小型、可組合。除非同步更新設計文件、測試與 man pages，否則不要把 policy 搬到不該負責的 applet。

| Component | 負責事項 | 不應負責 |
| --- | --- | --- |
| `pipeline_dispatcher` | 讀取 config、session lock、用 `pipe()`、`fork()`、`execv()`、signal handling、`waitpid()` 建立並監督 process pipeline，以及傳遞 exit code | 解析 clip JSON、決定 clip boundary、實作 storage internals、接收 network packets |
| `stream_merge` | 讀取 `.bin` 與 `.meta.jsonl`，解析 sidecar rows，執行 FSM，決定 clip records，輸出 clip JSON Lines | 永久儲存 records、解析任意 log、接 socket、decode 或 transcode media |
| `log_parse` | 從 stdin 讀資料，以 POSIX extended regex 擷取欄位，過濾 JSONL/records，輸出 JSON/CSV/count，並做聚合統計 | 直接讀 session directory、寫入 `clips.db`、管理 child processes |
| `clip_store` | 以 append-only file-backed KV store 持久化資料，支援 TTL、tombstone、query、prefix scan、file locking、compression、compaction | 接收 packets、決定 clip boundaries、解析或切影片 |
| `lib/` | 共用 helper：JSONL utilities、logging、dynamic buffers、Base64、miniz export wrappers、path helpers | 特定 applet 的政策邏輯 |
| `scripts/example/` | 提供 UDP/full-run flow 的 demo 與 contract evidence | 測試應依賴的核心 applet 行為 |
| `scripts/benchmark/` | 可重現 benchmark data generation 與 benchmark runners | 使用者面向的 applet logic |

---

## 5. 行為契約

### 5.1 UNIX stream discipline

每個 applet 都必須可以被 pipe 串接：

```text
box stream_merge <session_id> <src_dir> \
  | box log_parse --filter type=clip \
  | box clip_store --db /tmp/clips.db
```

規則：

- `stdout` 只放結構化資料。
- `stderr` 放 diagnostic、warning、progress message、error。
- `--help` 可以把 usage text 印到 `stdout`。
- 錯誤訊息與 debug log 不可以混進 pipeline data。
- 一筆 JSONL record 應占一行。

**好的寫法：**

```c
LOG_WARN("skipping invalid metadata line: %s", line);
```

**不好的寫法：**

```c
printf("parsed one record\n");
```

### 5.2 `pipeline_dispatcher` 行為契約

`pipeline_dispatcher` 是 process lifecycle 與 topology manager。

需要維持的行為：

- spawn child processes 前先驗證 session arguments 與 paths。
- 使用 session-level locking，避免同一個 session 重複啟動 pipeline。
- 建立以下三段 pipeline：

  ```text
  stream_merge -> log_parse -> clip_store
  ```

- 使用 `pipe()` 連接 applet 間的資料流。
- 使用 `fork()` 與 `execv()` 或等價 POSIX process execution。
- parent 與 child process 都要關閉不需要的 file descriptors。
- 一致地處理或轉送 termination signals。
- 使用 `waitpid()` 回收 child 狀態。
- 任何必要 child 失敗時，應回傳有意義的 non-zero status。

`pipeline_dispatcher` 不應解析 clip payload，也不應決定 storage-specific policy。

### 5.3 `stream_merge` 行為契約

`stream_merge` 是 **sidecar-driven clip indexer**。它不應解析 media codec，也不應 decode payload bytes。

需要維持的行為：

- 優先解析必要 scalar metadata fields：`kind`、`sequence`、`offset`、`length`、`ts_ms`。
- 遇到 malformed metadata row 時，在可恢復的情況下略過該 row，並把診斷訊息輸出到 `stderr`。
- 透過 FSM 將輸出分類為 `complete`、`partial`、`rejected`。
- 偵測 sequence gap、duplicate chunk、late chunk、offset discontinuity、idle/final flush cases。
- 無法證明連續性時，優先使用較安全的 `metadata_boundary`。
- 只有在 metadata 能證明連續性，且 byte-rate/frame-alignment 條件符合時，才使用 `continuous_byte_range`。
- 若 schema 支援 optional event information，應保留該資訊。
- clip JSONL records 只能輸出到 `stdout`。

`stream_merge` 不負責真正切影片。它輸出的是描述 byte ranges 的 clip objects。

### 5.4 `log_parse` 行為契約

`log_parse` 是 stdin-to-stdout 的結構化日誌處理器。

需要維持的功能：

| Option | Contract |
| --- | --- |
| `--regex <pattern>` / `-r <pattern>` | 使用 POSIX extended regular expressions 擷取欄位。 |
| `--fields <f1,f2,...>` / `-e <f1,f2,...>` | 將 capture groups 對應到欄位名稱。 |
| `--filter <expr>` / `-f <expr>` | 支援 `=`、`!=`、`>`、`~` 四種運算子。 |
| `--format json` | 輸出 JSON Lines。 |
| `--format csv` | 輸出 CSV rows。 |
| `--format count` | 只計算通過 filter 的 records，不輸出完整 records。 |
| `--build-full-log <path>` | 將 parsed structured records append 到 audit JSONL 檔。 |
| `--sum`、`--avg`、`--min`、`--max` | 執行 streaming numeric aggregation。 |
| `-E` | 接受 compatibility flag；程式永遠使用 extended regex。 |
| `-h`、`--help` | 顯示 help 並退出。 |

`log_parse` 可支援 regex-extracted records 與既有 JSONL input，但行為必須寫入文件並有測試覆蓋。

### 5.5 `clip_store` 行為契約

`clip_store` 是輕量級 append-only KV-backed record store。

需要維持的功能：

| Option | Contract |
| --- | --- |
| `--db <path>` / `-d <path>` | 必填 DB path。 |
| default stdin ingest | 從 stdin 讀取 clip JSONL 並 append records。 |
| `--ttl <seconds>` / `-t <seconds>` | 控制 record lifetime；`0` 代表不過期。 |
| `--set <k=v>` | 新增或更新 key-value record。 |
| `--get <key>` | 回傳指定 key 的最新 live value。 |
| `--list` | 列出所有 live key-value rows。 |
| `--prefix <prefix>` | 列出 key 以 prefix 開頭的 live rows。 |
| `--delete <key>` | append tombstone delete marker。 |
| `--compact` | 重寫 DB，只保留最新 live rows。 |
| `--gc` | `--compact` 的 alias。 |
| `-h`、`--help` | 顯示 help 並退出。 |

Storage rules：

- 一般寫入時 DB 採 append-only。
- 空字串 value 代表 tombstone。
- 同一個 key 後寫覆蓋先寫。
- expired rows 不算 live。
- 適用時 value 可用 Zlib/miniz 壓縮並以 Base64 編碼。
- 可能發生競爭的寫入必須使用 file locking。
- compaction 必須透過 temporary file 加 atomic `rename()` 完成。

---

## 6. 開發環境

### 需求

請使用 POSIX-like 環境：

- Linux、macOS 或 WSL2
- C11 compiler：`cc`、GCC 或 Clang
- GNU Make
- POSIX shell utilities
- Optional：`valgrind`、`clang-format`、`perf`、`jq`、`awk`、`ffmpeg`

### Clone 與初始化 dependencies

本 repository 使用 `cJSON`、`miniz` 等 third-party submodules。

```bash
git clone <repo-url>
cd stream-data-pipeline
git submodule update --init --recursive
```

如果 `.third-party/cJSON` 或 `.third-party/miniz` 是空的，請再次執行 submodule 指令。

### Build

```bash
make
```

Build outputs 會放在 `.build/`：

```text
.build/box
.build/pipeline_dispatcher
.build/stream_merge
.build/log_parse
.build/clip_store
```

本專案採 BusyBox-style single binary。`.build/` 裡的 applet paths 是指向 `.build/box` 的 symlinks。

### Debug build

```bash
make clean
CFLAGS="-std=c11 -g -O0 -Wall -Wextra -Wpedantic -D_POSIX_C_SOURCE=200809L" make
```

### Tests

```bash
make test
make smoke
```

### Benchmarks

```bash
bash scripts/benchmark/run_all.sh
```

Benchmark scripts 可能依賴 optional tools。若 benchmark 無法執行，請在 PR 中說明缺少的 command 與環境。

### Man pages

不安裝也可以預覽 local man pages：

```bash
man ./man/pipeline_dispatcher.1
man ./man/stream_merge.1
man ./man/log_parse.1
man ./man/clip_store.1
```

---

## 7. 程式碼風格

### C style

- 使用 4 spaces 縮排，不使用 tabs。
- 行長目標 100 characters，盡量不要超過 120 characters。
- 函數與變數使用 `snake_case`。
- Macro 與常數使用 `SCREAMING_SNAKE_CASE`。
- File-local functions 使用 `static`。
- 函數應保持專注且不要過長。
- 優先使用清楚命名，除非是常見縮寫，例如 `fd`、`len`、`ts_ms`、`ctx`。
- 檢查 system calls 與 library calls 的 return values。
- 每條 error path 都要正確釋放記憶體。
- allocated memory 的 ownership rules 要清楚。

範例：

```c
static int read_sidecar_line(FILE *fp, char *buf, size_t cap) {
    if (fp == NULL || buf == NULL || cap == 0) {
        return -1;
    }

    if (fgets(buf, cap, fp) == NULL) {
        return feof(fp) ? 0 : -1;
    }

    return 1;
}
```

### Error handling

- 使用有意義的 exit codes。
- Diagnostics 應包含 context，例如 file path、line number、operation 或 key。
- 不要忽略 `scanf`、`read`、`write`、`fopen`、`malloc`、`fork`、`pipe`、`exec`、`waitpid` 的結果。
- applet diagnostics 優先使用專案 logging helpers。

### Header files

- Public declarations 放在 `.h` files。
- 使用 include guards。
- Headers 應保持最小化，避免 circular includes。
- Applet-specific headers 放在 applet directory。
- Shared library headers 放在 `lib/`。

### Shell scripts

Shell tests 與 helper scripts 應保持 POSIX-compatible，除非明確標示需要 Bash。

建議格式：

```sh
#!/bin/sh
set -eu

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
```

規則：

- 變數要加引號：`"$var"`，不要寫 `$var`。
- Local shell variables 使用 lowercase；Environment variables 使用 uppercase。
- 除 `/tmp` 下的 controlled fixtures 外，避免 machine-specific absolute paths。

---

## 8. 測試要求

每個行為變更都應該補測試。

| Area | Test location |
| --- | --- |
| Shared library helpers | `tests/lib/` |
| Applet internal logic | `tests/applets/<applet>/` |
| End-to-end applet behavior | `tests/test_<applet>.sh` |
| Full dispatcher pipeline | `tests/test_pipeline_dispatcher.sh`、`make smoke` |

PR 前最低限度請執行：

```bash
make clean && make
make test
make smoke
```

Memory-sensitive changes 也建議執行：

```bash
valgrind --leak-check=full ./.build/stream_merge <args>
valgrind --leak-check=full ./.build/log_parse <args>
valgrind --leak-check=full ./.build/clip_store <args>
```

### 建議覆蓋案例

- 正常輸入與空輸入
- Malformed JSON Lines
- 缺少 `.bin`、`.meta.jsonl` 或 `.pipeline_end`
- Sequence gaps、duplicate chunks、late chunks
- FSM complete、partial、reject actions
- `metadata_boundary` 與 `continuous_byte_range` selection
- EOF、idle timeout、final flush behavior
- `log_parse` filter operators：`=`、`!=`、`>`、`~`
- JSON、CSV、count output formats
- Aggregation：sum、average、min、max
- `clip_store` TTL、tombstone delete、prefix query、compaction
- Concurrent writes 或 lock-sensitive operations（相關時）
- 大量輸入時 memory usage 應維持 bounded

### Test helper style

```sh
check_eq() {
    name=$1
    expected=$2
    actual=$3
    if [ "$expected" != "$actual" ]; then
        printf 'FAIL %s\nexpected: %s\nactual:   %s\n' "$name" "$expected" "$actual" >&2
        exit 1
    fi
}
```

---

## 9. Benchmark 與效能規則

Benchmark 必須公平且可重現。

與 GNU、Toybox 或其他 tools 比較時，請先分類比較類型：

| Type | Meaning | Acceptable claim |
| --- | --- | --- |
| A | CLI behavior equivalent | 可直接比較 throughput |
| B | Same problem domain，但 CLI 或 flags 不同 | 可做問題域比較 |
| C | 用多個 tools 組合出近似行為 | 可做 pipeline-composition comparison |

Guidelines：

- 記錄 OS、shell、CPU、compiler、optimization flags、input size、command line。
- 測 embedded-like behavior 時，分開 baseline 與 constrained runs。
- 若使用 cgroups，請記錄 memory limit、CPU quota、allowed CPU set 等設定。
- 說清楚正在量測的是 parsing、filtering、aggregation、storage ingest、compression 還是 IPC overhead。
- 不要宣稱專用 applet 可以完整取代 `jq`、`awk`、LIVE555、GStreamer 或 FFmpeg 這類通用工具。
- 若專用 applet 在單一任務勝出，請明確寫出勝出的是哪個狹窄任務。
- 若組合 baseline 在某些面向勝出（例如 compression ratio），也要如實呈現。
- Raw results 或 scripts 應放在 `scripts/benchmark/` 或 `.docs/benchmark.md`。

建議 benchmark report 格式：

```text
Environment:
  OS:
  CPU:
  Compiler:
  CFLAGS:
  Memory limit:
  CPU quota:
  Input size:

Comparison type:
  A / B / C

Commands:
  ours:
  baseline:

Results:
  baseline mode:
  constrained mode:

Interpretation:
  What the result proves:
  What the result does not prove:
```

---

## 10. 文件維護規則

當 code behavior 改變時，請同步更新對應文件。

| Change type | Files to check |
| --- | --- |
| CLI option 或 usage | `README.md`、`man/*.1`、`.docs/applets/*.md` |
| Applet behavior | `.docs/applets/<applet>.md`、tests |
| Session artifact contract | `README.md`、`.docs/core/overview.md`、`.docs/core/compliance.md` |
| Dispatcher lifecycle 或 process behavior | `.docs/applets/pipeline-dispatcher.md`、tests |
| Benchmark method 或 result | `.docs/benchmark.md`、`scripts/benchmark/` |
| Build 或 dependency change | `README.md`、`Makefile`、本 contributing guide |
| Demo script behavior | `README.md`、`scripts/example/`、相關 docs |

`README.md` 應保持 high-level 且 user-focused。更深入的 implementation notes 請放到 `.docs/`。

更新 diagrams、reports 或簡報素材時，請保持術語一致：

```text
pipeline_dispatcher    stream_merge         log_parse
clip_store             .pipeline_end        metadata_boundary
continuous_byte_range  append-only          tombstone
compaction             clip object          session artifact
```

Committed documentation 中請避免不一致拼法，例如 `pipline`、`CONTROBUTING` 或 `.pipline_end`。

---

## 11. Git 工作流程

1. Fork repository。
2. Clone 你的 fork。
3. 若需要，設定 upstream remote：`git remote add upstream <repo-url>`。
4. 從 `main` 建立 focused branch。
5. 進行變更。
6. 新增或更新測試。
7. 行為改變時同步更新文件。
8. 執行 local checks。
9. Push branch。
10. Open pull request。

建議 branch names：

```text
feat/log-parse-aggregate
fix/stream-merge-gap
refactor/pipeline-dispatcher-cleanup
docs/update-cli-contract
test/clip-store-gc
perf/log-parse-filter
```

PR 應保持 focused。如果一個 PR 同時改 applet behavior、storage format、benchmark scripts 與 documentation，除非這些變更高度相關，否則會很難 review。

---

## 12. Commit 訊息格式

使用以下格式：

```text
[type]: short description
```

常見 types：

| Type | 用途 |
| --- | --- |
| `init` | 專案初始化 |
| `feat` | 新功能 |
| `fix` | Bug fix |
| `docs` | 純文件變更 |
| `test` | 新增或修正測試 |
| `refactor` | 不改行為的程式重構 |
| `style` | 純格式調整 |
| `chore` | Build、tooling、dependency、maintenance |
| `perf` | 效能改善 |

範例：

```text
[feat]: add ttl option to clip_store
[fix]: handle sidecar eof in stream_merge
[docs]: update dispatcher lifecycle contract
[test]: add malformed jsonl filter case
[perf]: reduce log_parse json filter allocations
```

建議：

- 使用命令式語氣：`add`，不要寫 `added`。
- 第一行保持簡短（72 characters 以內）。
- 需要設計背景時，加入 commit body。
- 有相關 issue 時請引用。

---

## 13. Pull Request 要求

PR description 應包含：

- 改了什麼，以及為什麼需要這個變更
- 如何測試
- 是否有 compatibility impact
- 若與效能相關，是否有 benchmark impact
- 相關 issue number（如果有的話）

Reviewer 會看：

- Correctness 與責任邊界
- Stream discipline（`stdout`/`stderr` 分離）
- Error handling 與有意義的 exit codes
- Memory ownership 與 leak safety
- 新行為的測試覆蓋
- 文件更新
- C11/POSIX 相容性

Code review 不是批評。目標是讓專案可靠、容易理解，也容易展示。

---

## 14. Issue 回報與故障排除

回報 bug 時，請提供：

- Operating system 與 shell
- Compiler version：`cc --version` 或 `gcc --version`
- 實際執行的 command
- Sample input files 或 minimal JSON Lines input
- Expected output 與 actual output
- 完整 `stderr` 訊息
- 問題是否出現在 `make test`、`make smoke` 或 demo script

好的 issue title 格式：

```text
[BUG] stream_merge emits duplicate clip after sequence gap
[BUG] log_parse --filter drops valid nested field record
[BUG] clip_store gc rewrites ttl-expired record
```

常見 troubleshooting commands：

```bash
# 更新 submodules
git submodule update --init --recursive

# 從乾淨狀態重編
make clean && make

# 跑測試
make test && make smoke

# 查看 applet help
./.build/log_parse --help
./.build/clip_store --help
./.build/stream_merge --help
```

PR 有 conflict 時：

```bash
git fetch upstream
git rebase upstream/main
# resolve conflicts
git add .
git rebase --continue
git push origin --force-with-lease <branch-name>
```

---

## 15. 相容性與目前限制

Compatibility rules：

- 核心實作維持 C11 與 POSIX APIs。
- 不要要求 Linux-only features，除非有 guard 或明確文件說明。
- Shell tests 維持 POSIX `sh`，除非明確需要 Bash。
- 專案宣稱 GNU/Toybox-style CLI compatibility 的地方要維持相容。
- 避免 heavyweight runtime dependencies。
- Streaming workloads 的 memory usage 應保持 bounded。

目前限制：

- 本專案主要是 metadata 與 clip-index pipeline。
- `stream_merge` 不做 codec-aware video cutting。
- `clips.db` 儲存 clip records，不儲存完整 media payloads。
- Media extraction/remuxing 屬於 demo scripts 或未來 media extraction 工作。
- 嚴重損壞 session 的 advanced recovery 屬於未來工作，除非已明確實作並測試。
- Persistent on-disk secondary indexes 可能是未來工作；若改變目前行為，請寫入文件。

如果不可避免要新增 dependency 或 platform-specific feature，請說明原因，並同步更新 build files、docs、tests 與 benchmarks。

---

## 16. 提交前檢查清單

提交 PR 前，請確認：

- [ ] 已執行 `git submodule update --init --recursive`。
- [ ] `make clean && make` 通過。
- [ ] `make test` 通過。
- [ ] `make smoke` 通過。
- [ ] 沒有 diagnostic text 被印到 `stdout`。
- [ ] 新行為有測試。
- [ ] Memory-sensitive changes 已用 `valgrind` 或等價工具檢查。
- [ ] Session artifact names 保持相容（`.pipeline_end`，不是 `.pipline_end`）。
- [ ] CLI changes 已更新 `README.md`、`man/*.1`、`.docs/`。
- [ ] Benchmark claims 有標示 comparison type A、B 或 C。
- [ ] Commit messages 符合 `[type]: description`。
- [ ] PR 說明有寫清楚改了什麼以及如何測試。

---

## 17. 問題與資安回報

設計問題請開 issue，並附上足夠 context 與小型範例。

資安相關的問題**請勿開 public issue**，請透過 email 或 GitHub Private Security Advisory 私下聯絡 maintainers。

---

感謝你協助改進 `stream-data-pipeline`。

_最後更新：2026-06_
