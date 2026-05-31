# log_parse

`log_parse` 是 stdin -> stdout 的 structured log processor。它支援 regex 欄位提取、JSONL filter、即時聚合統計、輕量 count mode，以及 full structured log 建置。

## Parse Mode

```text
log_parse --regex <pattern> --fields a,b,c --format json|csv [-E]
```

- 從 stdin 逐行讀取。
- 使用 POSIX extended regex (支援 `-E` 參數相容 GNU grep)。
- 將 capture groups 依序映射到 `--fields` 欄位名。
- 對 stdout 輸出 JSON Lines 或 CSV。
- regex capture value 一律視為字串。
- 可搭配 `--build-full-log <path>`，將所有成功解析的 structured JSONL records 追加到完整 log，再依 filter 決定 stdout 是否輸出。

## Full Log Mode

```text
log_parse --build-full-log <path>
```

- 在 regex mode 中，成功解析的每一行都會以 JSONL 追加到 `<path>`。
- 在 JSONL filter mode 中，合法 JSON object 會原樣追加到 `<path>`。
- full log 寫入發生在 filter 之前，因此可作為 audit trail、replay input 或後續統計來源。

## Aggregation (統計) Mode

即時計算並輸出單一浮點數值：

```text
log_parse --sum <field>
log_parse --avg <field>
log_parse --max <field>
log_parse --min <field>
```

- 適用於過濾後的 JSONL 或是被 `--regex` 提取出的字串欄位。
- 在檔案/串流結束後，對 stdout 輸出計算結果（保留小數點後兩位）。

## Filter Mode

```text
log_parse --filter <expr>
```

- 從 stdin 讀取 JSON Lines。
- 只保留 top-level scalar 欄位符合條件的 records。
- pipeline 中預設用法是 `log_parse --filter type=clip`，但 demo 可搭配 `--build-full-log` 同時建立完整 structured event log。

支援的 filter expressions：

| Operator | 語意 | 範例 |
| --- | --- | --- |
| `=` | 等於 | `type=clip` |
| `!=` | 不等於 | `type!=heartbeat` |
| `>` | 數值大於 | `ts>1747065600` |
| `~` | 包含 substring | `path~/clips/` |

JSONL filter mode 預設會原樣 pass-through matching lines。

## Count Mode

```text
log_parse --filter type=clip --format count
log_parse --regex <pattern> --fields a,b,c --filter type=clip --format count
```

- 計算通過 filter 的 records 數量。
- 對 stdout 輸出一個十進位整數。
- regex parse mode 與 JSONL filter mode 都可使用。

## Format Rules

- `--format json` 與 `--format csv` 需要搭配 `--regex`。
- `--format count` 可搭配或不搭配 `--regex`。
- JSONL mode 若沒有 `--format count`，只做 pass-through，不把 JSONL 轉 CSV。

## 限制

- JSONL filter 只檢查 top-level fields。
- `>` 只接受 numeric values。
- `~` 會比對 scalar field 的文字表示。

## Stream Rule

- stdout：只輸出資料。
- stderr：只輸出 diagnostics。
