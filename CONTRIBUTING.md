# Contributing to stream-data-pipeline

Thank you for contributing to `stream-data-pipeline`.

This repository implements the **Embedded Stream Data Pipeline** final project: a C-based BusyBox-style toolset that turns append-only embedded session artifacts into structured clip metadata, filterable JSON Lines, and a lightweight file-backed clip index.

The core flow is:

```text
ESP32 / UDP-RTP-like stream / edge ingestor
  -> session artifact on disk
  -> pipeline_dispatcher
  -> stream_merge | log_parse --filter type=clip | clip_store
  -> clips.db
```

Read this guide before opening an issue, pull request, benchmark result, or documentation change.

---

## Table of Contents

1. [Project Philosophy](#1-project-philosophy)
2. [Project Scope and Session Artifact Contract](#2-project-scope-and-session-artifact-contract)
3. [What Contributions Are Welcome](#3-what-contributions-are-welcome)
4. [Architecture and Applet Responsibilities](#4-architecture-and-applet-responsibilities)
5. [Behavioral Contracts](#5-behavioral-contracts)
6. [Development Setup](#6-development-setup)
7. [Code Style](#7-code-style)
8. [Testing Expectations](#8-testing-expectations)
9. [Benchmark and Performance Rules](#9-benchmark-and-performance-rules)
10. [Documentation Rules](#10-documentation-rules)
11. [Git Workflow](#11-git-workflow)
12. [Commit Message Format](#12-commit-message-format)
13. [Pull Request Expectations](#13-pull-request-expectations)
14. [Issue Reports and Troubleshooting](#14-issue-reports-and-troubleshooting)
15. [Compatibility and Current Limits](#15-compatibility-and-current-limits)
16. [Pre-Submission Checklist](#16-pre-submission-checklist)
17. [Questions and Security](#17-questions-and-security)

---

## 1. Project Philosophy

`stream-data-pipeline` follows UNIX system programming principles:

- **Single responsibility** — each applet has one clear job.
- **Composition over monoliths** — tools are chained through pipes, not merged into a single binary.
- **Stream discipline** — `stdout` carries data only; `stderr` carries diagnostics only.
- **File-backed contracts** — session data is exchanged through append-only files and metadata sidecars.
- **Minimal dependencies** — the core is C11/POSIX-oriented and suitable for constrained embedded Linux-like environments.
- **Observable behavior** — CLI behavior, exit codes, tests, and documentation should make each change easy to verify.

Do not add features that make one applet do another applet's job. When in doubt, keep the pipeline smaller, more explicit, and easier to test.

---

## 2. Project Scope and Session Artifact Contract

This repository is the **downstream UNIX pipeline layer**. It is not a WebSocket server, a UDP/RTP packet receiver, an ESP32 parser, or a media transcoder.

An upper layer — such as `edge-ws-host` or a UDP demo server — is responsible for receiving packets and writing the session artifact to disk. This repository's work begins after the session artifact exists.

Expected session layout:

```text
/tmp/stream/{session_id}/
  {session_id}.bin
  {session_id}.meta.jsonl
  .pipeline_end
```

Artifact contract:

| File | Meaning | Contributor rule |
| --- | --- | --- |
| `{session_id}.bin` | Append-only binary payload buffer for the whole session | Do not rewrite earlier bytes during ingestion. |
| `{session_id}.meta.jsonl` | Sidecar metadata index with sequence, offset, length, timestamp, and optional events | Treat metadata as the source of truth for clip boundaries. |
| `.pipeline_end` | Sentinel marking that the session has ended | Use this exact spelling. Do not introduce `.pipline_end` or any other variant. |

Important assumptions:

- Data may originate from UDP/RTP-like transport, so chunk loss, gaps, duplicates, and late arrivals are possible.
- `.bin` stores raw appended bytes — it is not the index.
- `.meta.jsonl` is the byte-range index that tells the pipeline which part of `.bin` belongs to a clip.
- A clip index is not the same as a physical video file. `clips.db` stores clip records; extraction and remuxing belong to demo scripts or future media tooling.

---

## 3. What Contributions Are Welcome

### Features and applet improvements

- Improve `pipeline_dispatcher`, `stream_merge`, `log_parse`, or `clip_store` while preserving their responsibility boundaries.
- Add narrowly scoped CLI options with tests and man page updates.
- Improve edge cases: malformed metadata, EOF handling, gap handling, TTL behavior, compaction safety.

### Documentation and examples

- Improve `README.md`, `man/*.1`, `.docs/`, and example scripts.
- Add architecture explanations, sequence diagrams, or demo instructions.
- Fix terminology drift between code, documentation, benchmark notes, and presentation slides.

### Bugs and reliability

- Fix parsing, filtering, process lifecycle, file-locking, or storage bugs.
- Improve diagnostics without polluting `stdout`.
- Add regression tests for previously broken behavior.

### Performance and embedded constraints

- Reduce memory usage and unnecessary allocations.
- Improve streaming throughput.
- Improve benchmark reproducibility.
- Compare fairly against GNU/Toybox-style tools with the correct benchmark category.

### Testing

- Add unit tests for `lib/` and applet internals.
- Add shell integration tests for CLI behavior.
- Add end-to-end smoke tests for dispatcher pipelines.

Useful GitHub labels:

| Label | Meaning |
| --- | --- |
| `good first issue` | Small, beginner-friendly task |
| `help wanted` | Maintainers want outside help |
| `bug` | Incorrect behavior |
| `documentation` | Docs, examples, diagrams, man pages |
| `enhancement` | Feature or improvement request |
| `performance` | Throughput, memory, or benchmark work |
| `question` | Design discussion |

---

## 4. Architecture and Applet Responsibilities

The full project flow:

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

Keep each applet small and composable. Do not move policy across applet boundaries unless the design document, tests, and man pages are updated together.

| Component | Responsibility | Must not do |
| --- | --- | --- |
| `pipeline_dispatcher` | Load config, lock a session, build and supervise the process pipeline with `pipe()`, `fork()`, `execv()`, signal handling, `waitpid()`, and exit-code propagation | Parse clip JSON, decide clip boundaries, implement storage internals, receive network packets |
| `stream_merge` | Read `.bin` and `.meta.jsonl`, parse sidecar rows, run FSM logic, decide clip records, emit clip JSON Lines | Persist records, parse arbitrary logs, receive sockets, decode or transcode media |
| `log_parse` | Read stdin, extract fields with POSIX extended regex, filter JSONL/records, format JSON/CSV/count output, aggregate values | Read session directories, write `clips.db`, manage child processes |
| `clip_store` | Persist records in an append-only file-backed KV store with TTL, tombstones, query, prefix scan, file locking, compression, and compaction | Receive packets, decide clip boundaries, parse or cut media |
| `lib/` | Shared helpers: JSONL utilities, logging, dynamic buffers, Base64, miniz export wrappers, path helpers | Applet-specific policy |
| `scripts/example/` | Demo and contract evidence for UDP/full-run flows | Core applet behavior that tests depend on |
| `scripts/benchmark/` | Reproducible benchmark data generation and runners | User-facing applet logic |

---

## 5. Behavioral Contracts

### 5.1 UNIX stream discipline

Every applet must be usable in a pipeline:

```text
box stream_merge <session_id> <src_dir> \
  | box log_parse --filter type=clip \
  | box clip_store --db /tmp/clips.db
```

Rules:

- `stdout` is for structured data only.
- `stderr` is for diagnostics, warnings, progress, and errors.
- `--help` may print usage text to `stdout`.
- Error messages and debug logs must never appear in pipeline data.
- One JSONL record occupies one line.

**Good:**

```c
LOG_WARN("skipping invalid metadata line: %s", line);
```

**Bad:**

```c
printf("parsed one record\n");
```

### 5.2 `pipeline_dispatcher` contract

`pipeline_dispatcher` is the process lifecycle and topology manager.

Behaviors to preserve:

- Validate session arguments and paths before spawning children.
- Use session-level locking to prevent duplicate pipeline execution for the same session.
- Build the three-stage pipeline:

  ```text
  stream_merge -> log_parse -> clip_store
  ```

- Use `pipe()` for inter-applet communication.
- Use `fork()` and `execv()` or equivalent POSIX process execution.
- Close unused file descriptors in both parent and child.
- Forward or handle termination signals consistently.
- Use `waitpid()` to collect child status.
- Return a meaningful non-zero status if any required child fails.

`pipeline_dispatcher` must not parse clip payloads or make storage-specific decisions.

### 5.3 `stream_merge` contract

`stream_merge` is a **sidecar-driven clip indexer**. It does not inspect media codecs or decode payload bytes.

Behaviors to preserve:

- Parse required scalar metadata fields first: `kind`, `sequence`, `offset`, `length`, `ts_ms`.
- Treat malformed metadata rows as recoverable: skip the row and emit diagnostics to `stderr`.
- Use FSM logic to classify output as `complete`, `partial`, or `rejected`.
- Detect sequence gaps, duplicate chunks, late chunks, offset discontinuity, and idle/final flush cases.
- Prefer safe `metadata_boundary` when continuity cannot be proven.
- Use `continuous_byte_range` only when metadata proves a continuous stream and byte-rate/frame-alignment conditions are met.
- Preserve optional event information when supported by the documented schema.
- Emit clip JSONL records only to `stdout`.

`stream_merge` does not cut real video. It emits clip objects that identify byte ranges.

### 5.4 `log_parse` contract

`log_parse` is a stdin-to-stdout structured log processor.

Supported behavior to preserve:

| Option | Contract |
| --- | --- |
| `--regex <pattern>` / `-r <pattern>` | Use POSIX extended regular expressions to extract fields. |
| `--fields <f1,f2,...>` / `-e <f1,f2,...>` | Map capture groups to field names. |
| `--filter <expr>` / `-f <expr>` | Support `=`, `!=`, `>`, and `~` operators. |
| `--format json` | Output JSON Lines. |
| `--format csv` | Output CSV rows. |
| `--format count` | Count passing records without emitting full records. |
| `--build-full-log <path>` | Append parsed structured records to an audit JSONL file. |
| `--sum`, `--avg`, `--min`, `--max` | Perform streaming numeric aggregation. |
| `-E` | Accept as compatibility flag; extended regex is always used. |
| `-h`, `--help` | Print help and exit. |

`log_parse` may support both regex-extracted records and existing JSONL input, but the behavior must be documented and tested.

### 5.5 `clip_store` contract

`clip_store` is a lightweight append-only KV-backed record store.

Supported behavior to preserve:

| Option | Contract |
| --- | --- |
| `--db <path>` / `-d <path>` | Required DB path. |
| default stdin ingest | Read clip JSONL from stdin and append records. |
| `--ttl <seconds>` / `-t <seconds>` | Control record lifetime; `0` means no expiry. |
| `--set <k=v>` | Add or update a key-value record. |
| `--get <key>` | Return the latest live value for a key. |
| `--list` | List all live key-value rows. |
| `--prefix <prefix>` | List live rows whose keys start with the prefix. |
| `--delete <key>` | Append a tombstone delete marker. |
| `--compact` | Rewrite the DB keeping only the latest live rows. |
| `--gc` | Alias of `--compact`. |
| `-h`, `--help` | Print help and exit. |

Storage rules:

- The DB is append-only during normal writes.
- An empty value is a tombstone.
- Later records override earlier records for the same key.
- Expired rows are not live.
- Values may be compressed with Zlib/miniz and Base64-encoded when applicable.
- Writes that may race must use file locking.
- Compaction must use a temporary file and an atomic `rename()`.

---

## 6. Development Setup

### Requirements

Use a POSIX-like environment:

- Linux, macOS, or WSL2
- C11 compiler: `cc`, GCC, or Clang
- GNU Make
- POSIX shell utilities
- Optional: `valgrind`, `clang-format`, `perf`, `jq`, `awk`, `ffmpeg`

### Clone and initialize dependencies

This repository uses third-party submodules including `cJSON` and `miniz`.

```bash
git clone <repo-url>
cd stream-data-pipeline
git submodule update --init --recursive
```

If `.third-party/cJSON` or `.third-party/miniz` is empty, re-run the submodule command.

### Build

```bash
make
```

Build outputs are placed in `.build/`:

```text
.build/box
.build/pipeline_dispatcher
.build/stream_merge
.build/log_parse
.build/clip_store
```

The project uses a BusyBox-style single binary. Applet paths in `.build/` are symlinks to `.build/box`.

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

Benchmark scripts may depend on optional tools. If a benchmark cannot run, document the missing commands and environment in the PR.

### Man pages

Preview local man pages without installing:

```bash
man ./man/pipeline_dispatcher.1
man ./man/stream_merge.1
man ./man/log_parse.1
man ./man/clip_store.1
```

---

## 7. Code Style

### C style

- Use 4 spaces for indentation, not tabs.
- Target line length: 100 characters; avoid exceeding 120 characters.
- Use `snake_case` for functions and variables.
- Use `SCREAMING_SNAKE_CASE` for macros and constants.
- Mark file-local functions `static`.
- Keep functions focused and reasonably short.
- Prefer clear names; common abbreviations like `fd`, `len`, `ts_ms`, and `ctx` are fine.
- Check return values from every system call and library call.
- Free memory on every error path.
- Keep ownership rules explicit for allocated memory.

Example:

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

- Use meaningful exit codes.
- Include context in diagnostics: file path, line number, operation, or key.
- Never ignore results from `scanf`, `read`, `write`, `fopen`, `malloc`, `fork`, `pipe`, `exec`, or `waitpid`.
- Use project logging helpers for applet diagnostics.

### Header files

- Public declarations belong in `.h` files.
- Use include guards.
- Keep headers minimal; avoid circular includes.
- Put applet-specific headers under the applet directory.
- Put shared library headers under `lib/`.

### Shell scripts

Shell tests and helper scripts should be POSIX-compatible unless Bash is explicitly documented as required.

Recommended template:

```sh
#!/bin/sh
set -eu

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
```

Rules:

- Quote variables: `"$var"`, not `$var`.
- Use lowercase for local shell variables; uppercase for environment variables.
- Avoid machine-specific absolute paths except controlled fixtures under `/tmp`.

---

## 8. Testing Expectations

Every behavior change must include tests.

| Area | Location |
| --- | --- |
| Shared library helpers | `tests/lib/` |
| Applet internal logic | `tests/applets/<applet>/` |
| End-to-end applet behavior | `tests/test_<applet>.sh` |
| Full dispatcher pipeline | `tests/test_pipeline_dispatcher.sh`, `make smoke` |

Minimum checks before opening a PR:

```bash
make clean && make
make test
make smoke
```

For memory-sensitive changes, also run:

```bash
valgrind --leak-check=full ./.build/stream_merge <args>
valgrind --leak-check=full ./.build/log_parse <args>
valgrind --leak-check=full ./.build/clip_store <args>
```

### Cases to cover

- Normal input and empty input
- Malformed JSON Lines
- Missing `.bin`, `.meta.jsonl`, or `.pipeline_end`
- Sequence gaps, duplicate chunks, and late chunks
- FSM complete, partial, and rejected actions
- `metadata_boundary` vs `continuous_byte_range` selection
- EOF, idle timeout, and final flush behavior
- `log_parse` filter operators: `=`, `!=`, `>`, `~`
- JSON, CSV, and count output formats
- Aggregation: sum, average, min, max
- `clip_store` TTL, tombstone delete, prefix query, and compaction
- Concurrent writes and lock-sensitive operations where relevant
- Bounded memory usage under large input

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

## 9. Benchmark and Performance Rules

Benchmarks must be fair and reproducible.

When comparing against GNU, Toybox, or other tools, classify the comparison type first:

| Type | Meaning | Acceptable claim |
| --- | --- | --- |
| A | CLI behavior equivalent | Direct throughput comparison |
| B | Same problem domain, different CLI or flags | Problem-domain comparison |
| C | Several tools composed to approximate the same behavior | Pipeline-composition comparison |

Guidelines:

- Record OS, shell, CPU, compiler, optimization flags, input size, and command line.
- Separate baseline and constrained runs when measuring embedded-like behavior.
- If using cgroups, document memory limit, CPU quota, and allowed CPU set.
- State clearly what is being measured: parsing, filtering, aggregation, storage ingest, compression, or IPC overhead.
- Do not claim a specialized applet is a full replacement for general-purpose tools like `jq`, `awk`, LIVE555, GStreamer, or FFmpeg.
- If a specialized applet wins on a narrow task, name that narrow task explicitly.
- If a composed baseline wins on one dimension such as compression ratio, report it honestly.
- Store raw results or scripts under `scripts/benchmark/` or `.docs/benchmark.md`.

Recommended benchmark report format:

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

## 10. Documentation Rules

When code behavior changes, update the matching documentation.

| Change type | Files to update |
| --- | --- |
| CLI option or usage | `README.md`, `man/*.1`, `.docs/applets/*.md` |
| Applet behavior | `.docs/applets/<applet>.md`, tests |
| Session artifact contract | `README.md`, `.docs/core/overview.md`, `.docs/core/compliance.md` |
| Dispatcher lifecycle | `.docs/applets/pipeline-dispatcher.md`, tests |
| Benchmark method or result | `.docs/benchmark.md`, `scripts/benchmark/` |
| Build or dependency | `README.md`, `Makefile`, this contributing guide |
| Demo script behavior | `README.md`, `scripts/example/`, related docs |

Keep `README.md` high-level and user-focused. Put deeper implementation notes in `.docs/`.

When updating diagrams, reports, or presentation material, use consistent terminology:

```text
pipeline_dispatcher    stream_merge         log_parse
clip_store             .pipeline_end        metadata_boundary
continuous_byte_range  append-only          tombstone
compaction             clip object          session artifact
```

Avoid misspellings such as `pipline`, `CONTROBUTING`, or `.pipline_end` in committed documentation.

---

## 11. Git Workflow

1. Fork the repository.
2. Clone your fork.
3. Add the upstream remote if needed: `git remote add upstream <repo-url>`.
4. Create a focused branch from `main`.
5. Make the change.
6. Add or update tests.
7. Update docs when behavior changes.
8. Run local checks.
9. Push the branch.
10. Open a pull request.

Suggested branch naming:

```text
feat/log-parse-aggregate
fix/stream-merge-gap
refactor/pipeline-dispatcher-cleanup
docs/update-cli-contract
test/clip-store-gc
perf/log-parse-filter
```

Keep PRs focused. A PR that changes applet behavior, storage format, benchmark scripts, and documentation all at once is difficult to review unless those changes are tightly connected.

---

## 12. Commit Message Format

```text
[type]: short description
```

| Type | Use for |
| --- | --- |
| `init` | Project initialization |
| `feat` | New feature |
| `fix` | Bug fix |
| `docs` | Documentation-only change |
| `test` | Test addition or correction |
| `refactor` | Code restructuring without behavior change |
| `style` | Formatting-only change |
| `chore` | Build, tooling, dependency, or maintenance |
| `perf` | Performance improvement |

Examples:

```text
[feat]: add ttl option to clip_store
[fix]: handle sidecar eof in stream_merge
[docs]: update dispatcher lifecycle contract
[test]: add malformed jsonl filter case
[perf]: reduce log_parse json filter allocations
```

Tips:

- Use the imperative mood: `add`, not `added`.
- Keep the first line short (under 72 characters).
- Add a body when the change needs design context.
- Reference related issues when available.

---

## 13. Pull Request Expectations

A PR description should include:

- What changed and why
- How it was tested
- Any compatibility impact
- Benchmark impact, if performance-related
- Related issue number, if available

Reviewers will look for:

- Correctness and responsibility boundaries
- Stream discipline (`stdout`/`stderr` separation)
- Error handling and meaningful exit codes
- Memory ownership and leak safety
- Test coverage for new behavior
- Documentation updates
- C11/POSIX compatibility

Code review is not criticism. The goal is a reliable, understandable, and demonstrable project.

---

## 14. Issue Reports and Troubleshooting

When reporting a bug, include:

- Operating system and shell
- Compiler version (`cc --version` or `gcc --version`)
- Exact command used
- Sample input files or minimal JSON Lines input
- Expected output vs. actual output
- Full `stderr` output
- Whether the issue reproduces in `make test`, `make smoke`, or a demo script

Good issue title format:

```text
[BUG] stream_merge emits duplicate clip after sequence gap
[BUG] log_parse --filter drops valid nested field record
[BUG] clip_store gc rewrites ttl-expired record
```

Common troubleshooting commands:

```bash
# Update submodules
git submodule update --init --recursive

# Rebuild from a clean state
make clean && make

# Run tests
make test && make smoke

# Show applet help
./.build/log_parse --help
./.build/clip_store --help
./.build/stream_merge --help
```

For merge conflicts:

```bash
git fetch upstream
git rebase upstream/main
# resolve conflicts
git add .
git rebase --continue
git push origin --force-with-lease <branch-name>
```

---

## 15. Compatibility and Current Limits

Compatibility rules:

- Keep the core implementation in C11 and POSIX APIs.
- Do not require Linux-only features unless guarded or documented.
- Keep shell tests as POSIX `sh` unless Bash is explicitly required.
- Preserve GNU/Toybox-style CLI compatibility where the project claims it.
- Avoid heavyweight runtime dependencies.
- Keep memory usage bounded for streaming workloads.

Current limits:

- The project is primarily a metadata and clip-index pipeline.
- `stream_merge` does not perform codec-aware video cutting.
- `clips.db` stores clip records, not full media payloads.
- Media extraction/remuxing belongs to demo scripts or future media tooling.
- Advanced recovery for badly corrupted sessions is future work unless explicitly implemented and tested.
- Persistent on-disk secondary indexes are future work; document any change to current behavior.

If a new dependency or platform-specific feature is unavoidable, explain why and update build files, docs, tests, and benchmarks accordingly.

---

## 16. Pre-Submission Checklist

Before opening a pull request, verify:

- [ ] `git submodule update --init --recursive` has been run.
- [ ] `make clean && make` passes.
- [ ] `make test` passes.
- [ ] `make smoke` passes.
- [ ] No diagnostic text is printed to `stdout`.
- [ ] New behavior has tests.
- [ ] Memory-sensitive changes were checked with `valgrind` or equivalent.
- [ ] Session artifact names remain compatible (`.pipeline_end`, not `.pipline_end`).
- [ ] CLI changes update `README.md`, `man/*.1`, and `.docs/`.
- [ ] Benchmark claims identify comparison type A, B, or C.
- [ ] Commit messages follow `[type]: description`.
- [ ] The PR description explains what changed and how it was tested.

---

## 17. Questions and Security

For design questions, open an issue with enough context and a minimal example.

For security-sensitive reports, **do not open a public issue**. Contact the maintainers privately via email or a private GitHub security advisory.

---

Thank you for helping improve `stream-data-pipeline`.

_Last updated: 2026-06_
