#!/usr/bin/env bash
# run_all.sh — Resource-constrained benchmark for stream-data-pipeline
#
# Compares the three project applets (stream_merge, log_parse, clip_store) and
# the orchestrator (pipeline_dispatcher) against GNU/Toybox/alternative tools
# under embedded-class resource limits.
#
# Limit strategy (in priority order):
#   1. systemd-run --user --scope -p MemoryMax=64M -p CPUQuota=50% -p AllowedCPUs=0
#      (preferred — uses cgroup v2, captures memory.peak/cpu.stat)
#   2. Fallback: prlimit --as=64MB + taskset -c 0 (limits VM size + pins to CPU0)
#
# Results CSV: scripts/benchmark/results/results.csv
# Log dir:     scripts/benchmark/results/logs/

set -u
trap 'echo "[run_all.sh] interrupted" >&2; exit 130' INT TERM

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

# ---- Configuration ----
MEM_LIMIT_MB="${MEM_LIMIT_MB:-64}"
CPU_QUOTA="${CPU_QUOTA:-50}"
CPU_PIN="${CPU_PIN:-0}"
RUN_BASELINE="${RUN_BASELINE:-1}"
PHASES="${PHASES:-1 2 3 4 5 6 7}"

RESULTS_DIR="$REPO_ROOT/scripts/benchmark/results"
LOG_DIR="$RESULTS_DIR/logs"
CSV="$RESULTS_DIR/results.csv"
mkdir -p "$LOG_DIR"
# Reset CSV only when Phase 1 (dataset generation) is being run; otherwise append.
case " ${PHASES:-1 2 3 4 5 6 7} " in
    *" 1 "*) echo "phase,mode,tool,input_mb,seconds,throughput_mb_s,output_lines_or_bytes,max_rss_kb,notes" > "$CSV" ;;
    *) [ -f "$CSV" ] || echo "phase,mode,tool,input_mb,seconds,throughput_mb_s,output_lines_or_bytes,max_rss_kb,notes" > "$CSV" ;;
esac

BOX="$REPO_ROOT/.build/box"
STREAM_MERGE="$REPO_ROOT/.build/stream_merge"
LOG_PARSE="$REPO_ROOT/.build/log_parse"
CLIP_STORE="$REPO_ROOT/.build/clip_store"
PIPELINE_DISPATCHER="$REPO_ROOT/.build/pipeline_dispatcher"

banner() { printf '\n=========================================\n %s\n=========================================\n' "$1"; }

SYSTEMD_RUN_OK=0
if command -v systemd-run >/dev/null 2>&1; then
    if systemd-run --user --scope --quiet -p MemoryMax="${MEM_LIMIT_MB}M" -p CPUQuota="${CPU_QUOTA}%" true 2>/dev/null; then
        SYSTEMD_RUN_OK=1
    fi
fi
if command -v prlimit >/dev/null 2>&1 && command -v taskset >/dev/null 2>&1; then
    PRLIMIT_OK=1
else
    PRLIMIT_OK=0
fi
LIMIT_MODE="none"
if [ "$SYSTEMD_RUN_OK" = "1" ]; then LIMIT_MODE="systemd-run"
elif [ "$PRLIMIT_OK"  = "1" ]; then LIMIT_MODE="prlimit-taskset"
fi
echo "[run_all.sh] limit mode: $LIMIT_MODE (mem=${MEM_LIMIT_MB}M, cpu_quota=${CPU_QUOTA}%, pin=cpu${CPU_PIN})"

run_constrained() {
    local label="$1"; shift; [ "$1" = "--" ] && shift
    local rss_log="$LOG_DIR/${label}.rusage"
    local stderr_log="$LOG_DIR/${label}.stderr"
    local mem_bytes=$(( MEM_LIMIT_MB * 1024 * 1024 ))
    local rc
    if [ "$LIMIT_MODE" = "systemd-run" ]; then
        systemd-run --user --scope --quiet --collect \
            -p MemoryMax="${MEM_LIMIT_MB}M" \
            -p CPUQuota="${CPU_QUOTA}%" \
            -p AllowedCPUs="$CPU_PIN" \
            -- /usr/bin/time -v -o "$rss_log" -- "$@" 2>"$stderr_log"
        rc=$?
    elif [ "$LIMIT_MODE" = "prlimit-taskset" ]; then
        taskset -c "$CPU_PIN" prlimit --as=$mem_bytes -- \
            /usr/bin/time -v -o "$rss_log" -- "$@" 2>"$stderr_log"
        rc=$?
    else
        /usr/bin/time -v -o "$rss_log" -- "$@" 2>"$stderr_log"
        rc=$?
    fi
    if [ "$rc" -ne 0 ] && ! grep -q "Maximum resident" "$rss_log" 2>/dev/null; then
        echo "[warn] label=${label} exit=${rc} — rusage missing; likely OOM-killed before /usr/bin/time could write" >&2
    fi
    return $rc
}

run_baseline() {
    local label="$1"; shift; [ "$1" = "--" ] && shift
    local rss_log="$LOG_DIR/${label}.rusage"
    local stderr_log="$LOG_DIR/${label}.stderr"
    /usr/bin/time -v -o "$rss_log" -- "$@" 2>"$stderr_log"
}

read_rss_kb() {
    local rss
    rss=$(awk '/Maximum resident/ {print $NF}' "$1" 2>/dev/null)
    if [ -z "$rss" ]; then
        echo "[warn] RSS not found in ${1:-<no file>} — check /usr/bin/time is GNU time" >&2
        echo 0
    else
        echo "$rss"
    fi
}

WALL=0
_TIME_RUN_DEPTH=0
time_run() {
    if [ "$_TIME_RUN_DEPTH" -gt 0 ]; then
        echo "[warn] nested time_run call detected — WALL will be overwritten by inner call" >&2
    fi
    _TIME_RUN_DEPTH=$(( _TIME_RUN_DEPTH + 1 ))
    local t0 t1 rc
    t0=$(date +%s.%N)
    "$@"
    rc=$?
    t1=$(date +%s.%N)
    WALL=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.4f", b-a}')
    _TIME_RUN_DEPTH=$(( _TIME_RUN_DEPTH - 1 ))
    return $rc
}

mb_per_s() {
    awk -v mb="$1" -v sec="$2" 'BEGIN{ if(sec>0) printf "%.2f", mb/sec; else print "0.00" }'
}

csv_row() {
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$@" >> "$CSV"
}

for_each_mode() {
    local body_fn="$1"
    if [ "$RUN_BASELINE" = "1" ]; then
        MODE="baseline" "$body_fn"
    fi
    MODE="constrained" "$body_fn"
}

run_for_mode() {
    if [ "$MODE" = "baseline" ]; then
        time_run run_baseline "$@"
    else
        time_run run_constrained "$@"
    fi
}

want_phase() {
    case " $PHASES " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

banner "Phase 0: Environment & Prerequisites"
echo "Repo:      $REPO_ROOT"
echo "Limit:     $LIMIT_MODE"
echo "Mem cap:   ${MEM_LIMIT_MB} MB"
echo "CPU quota: ${CPU_QUOTA}% on cpu${CPU_PIN}"
echo "Baseline:  $RUN_BASELINE"
echo "Phases:    $PHASES"
echo "---"
uname -a
echo "CPU:       $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | sed 's/^ *//')"
echo "Cores:     $(nproc)"
echo "RAM:       $(free -h | awk '/^Mem:/{print $2}')"
echo "GCC:       $(cc --version | head -1)"
echo "awk:       $(awk --version 2>&1 | head -1)"
echo "grep:      $(grep --version | head -1)"
echo "jq:        $(jq --version 2>&1 || echo 'NOT INSTALLED')"
echo "sed:       $(sed --version 2>&1 | head -1)"
echo "gzip:      $(gzip --version | head -1)"

if [ ! -x "$BOX" ]; then
    echo "[run_all.sh] .build/box missing — building..."
    make -j2 || { echo "BUILD FAILED" >&2; exit 1; }
fi

TOYBOX=""
for cand in "$(command -v toybox)" /tmp/toybox-src/toybox /tmp/toybox; do
    if [ -n "$cand" ] && [ -x "$cand" ]; then TOYBOX="$cand"; break; fi
done
if [ -z "$TOYBOX" ]; then
    echo "[run_all.sh] toybox not found; building from source..."
    if [ ! -d /tmp/toybox-src ]; then
        git clone --depth 1 https://github.com/landley/toybox.git /tmp/toybox-src >/dev/null 2>&1 || true
    fi
    if [ -d /tmp/toybox-src ]; then
        ( cd /tmp/toybox-src && make defconfig >/dev/null 2>&1 && make -j2 >/dev/null 2>&1 ) || true
    fi
    [ -x /tmp/toybox-src/toybox ] && TOYBOX=/tmp/toybox-src/toybox
fi
echo "Toybox:    ${TOYBOX:-NOT AVAILABLE}"

if want_phase 1; then
banner "Phase 1: Generating Datasets"
rm -rf test_env && mkdir -p test_env
python3 scripts/benchmark/gen_data.py small
python3 scripts/benchmark/gen_data.py medium
python3 scripts/benchmark/gen_data.py jsonl
python3 - <<'PYAGG'
import random
random.seed(42)
with open("test_env/bench_text.log","w") as f:
    for i in range(100000):
        f.write(f"type=clip duration={random.randint(1,100)}\n")
PYAGG
python3 - <<'PYCS'
with open("test_env/bench_clip_store.jsonl","w") as f:
    for i in range(50000):
        if i % 5 == 0:
            f.write(f'{{"type":"clip","session_id":"sess_{i%100}","ts":{i*100},"duration":5,"path":"/tmp/video_{i}.mp4"}}\n')
        else:
            f.write(f'{{"type":"heartbeat","session_id":"sess_{i%100}","ts":{i*100}}}\n')
PYCS
ls -lh test_env/
fi

phase2_body() {
    local file="test_env/bench_medium.bin"
    local sidecar="test_env/bench_medium.meta.jsonl"
    [ -f "$file" ] || { echo "Phase 2 dataset missing"; return; }
    local size_mb=$(awk -v b=$(wc -c < "$file") 'BEGIN{printf "%.2f", b/1048576}')
    echo "[$MODE] stream_merge on $size_mb MB"
    rm -f test_env/sm_out.jsonl
    run_for_mode "p2_sm_${MODE}" -- "$STREAM_MERGE" bench_medium test_env > test_env/sm_out.jsonl
    local clips=$(wc -l < test_env/sm_out.jsonl)
    local rss=$(read_rss_kb "$LOG_DIR/p2_sm_${MODE}.rusage")
    local tp=$(mb_per_s "$size_mb" "$WALL")
    echo "    stream_merge      ${tp} MB/s  wall=${WALL}s  clips=${clips}  rss=${rss}kB"
    csv_row 2 "$MODE" stream_merge "$size_mb" "$WALL" "$tp" "$clips" "$rss" "C-class"

    echo "[$MODE] awk windowing"
    rm -f test_env/awk_win_out.txt
    local awk_prog='/"kind":"data"/ { for(i=1;i<=NF;i++){ if($i=="\"ts_ms\"") ts=$(i+1); if($i=="\"length\"") len=$(i+1); } if(start==0) start=ts; if(ts-start>=5000){count++; start=ts} } END { print count }'
    run_for_mode "p2_awk_${MODE}" -- awk -F'[:,}]' "$awk_prog" "$sidecar" >test_env/awk_win_out.txt
    local awk_rss=$(read_rss_kb "$LOG_DIR/p2_awk_${MODE}.rusage")
    local awk_tp=$(mb_per_s "$size_mb" "$WALL")
    echo "    awk windowing     ${awk_tp} MB/s  wall=${WALL}s  rss=${awk_rss}kB"
    csv_row 2 "$MODE" awk_windowing "$size_mb" "$WALL" "$awk_tp" 0 "$awk_rss" "C-class:windowing-only"
}
if want_phase 2; then banner "Phase 2: stream_merge vs awk windowing"; for_each_mode phase2_body; fi

phase3_body() {
    local file="test_env/bench_jsonl.jsonl"
    [ -f "$file" ] || { echo "Phase 3 dataset missing"; return; }
    local size_mb=$(awk -v b=$(wc -c < "$file") 'BEGIN{printf "%.2f", b/1048576}')
    echo "[$MODE] JSONL filter, input=${size_mb} MB"

    rm -f test_env/lp_out.jsonl
    run_for_mode "p3_lp_${MODE}" -- bash -c "\"$LOG_PARSE\" --filter type=clip < \"$file\" > test_env/lp_out.jsonl"
    local lp_lines=$(wc -l < test_env/lp_out.jsonl)
    local lp_rss=$(read_rss_kb "$LOG_DIR/p3_lp_${MODE}.rusage")
    local lp_tp=$(mb_per_s "$size_mb" "$WALL")
    echo "    log_parse          ${lp_tp} MB/s  wall=${WALL}s  lines=${lp_lines}  rss=${lp_rss}kB"
    csv_row 3 "$MODE" log_parse "$size_mb" "$WALL" "$lp_tp" "$lp_lines" "$lp_rss" "main"

    if command -v jq >/dev/null 2>&1; then
        rm -f test_env/jq_out.jsonl
        run_for_mode "p3_jq_${MODE}" -- bash -c "jq -c 'select(.type==\"clip\")' \"$file\" > test_env/jq_out.jsonl"
        local jq_exit=$?
        local jq_lines=$(wc -l < test_env/jq_out.jsonl 2>/dev/null || echo 0)
        local jq_rss=$(read_rss_kb "$LOG_DIR/p3_jq_${MODE}.rusage")
        local jq_tp=$(mb_per_s "$size_mb" "$WALL")
        local note="B-class:main"
        [ "$jq_exit" != "0" ] && note="B-class:FAILED(exit=$jq_exit)"
        echo "    jq                 ${jq_tp} MB/s  wall=${WALL}s  lines=${jq_lines}  rss=${jq_rss}kB  ($note)"
        csv_row 3 "$MODE" jq "$size_mb" "$WALL" "$jq_tp" "$jq_lines" "$jq_rss" "$note"
    fi

    rm -f test_env/awk_filter_out.jsonl
    run_for_mode "p3_awk_${MODE}" -- bash -c "awk -F'\"type\":\"' '{split(\$2,a,\"\\\"\"); if(a[1]==\"clip\") print}' \"$file\" > test_env/awk_filter_out.jsonl"
    local awk_lines=$(wc -l < test_env/awk_filter_out.jsonl)
    local awk_rss=$(read_rss_kb "$LOG_DIR/p3_awk_${MODE}.rusage")
    local awk_tp=$(mb_per_s "$size_mb" "$WALL")
    echo "    awk (sim JSON)     ${awk_tp} MB/s  wall=${WALL}s  lines=${awk_lines}  rss=${awk_rss}kB"
    csv_row 3 "$MODE" awk_simjson "$size_mb" "$WALL" "$awk_tp" "$awk_lines" "$awk_rss" "C-class"

    rm -f test_env/grep_out.jsonl
    run_for_mode "p3_grep_${MODE}" -- bash -c "grep '\"type\":\"clip\"' \"$file\" > test_env/grep_out.jsonl"
    local grep_lines=$(wc -l < test_env/grep_out.jsonl)
    local grep_rss=$(read_rss_kb "$LOG_DIR/p3_grep_${MODE}.rusage")
    local grep_tp=$(mb_per_s "$size_mb" "$WALL")
    echo "    GNU grep           ${grep_tp} MB/s  wall=${WALL}s  lines=${grep_lines}  rss=${grep_rss}kB (D-class)"
    csv_row 3 "$MODE" gnu_grep "$size_mb" "$WALL" "$grep_tp" "$grep_lines" "$grep_rss" "D-class"

    if [ -n "$TOYBOX" ]; then
        rm -f test_env/toybox_grep_out.jsonl
        run_for_mode "p3_tgrep_${MODE}" -- bash -c "\"$TOYBOX\" grep '\"type\":\"clip\"' \"$file\" > test_env/toybox_grep_out.jsonl"
        local tg_lines=$(wc -l < test_env/toybox_grep_out.jsonl)
        local tg_rss=$(read_rss_kb "$LOG_DIR/p3_tgrep_${MODE}.rusage")
        local tg_tp=$(mb_per_s "$size_mb" "$WALL")
        echo "    Toybox grep        ${tg_tp} MB/s  wall=${WALL}s  lines=${tg_lines}  rss=${tg_rss}kB (D-class)"
        csv_row 3 "$MODE" toybox_grep "$size_mb" "$WALL" "$tg_tp" "$tg_lines" "$tg_rss" "D-class"
    fi
}
if want_phase 3; then banner "Phase 3: log_parse --filter vs jq/awk/grep"; for_each_mode phase3_body; fi

phase4_body() {
    local file="test_env/bench_text.log"
    [ -f "$file" ] || { echo "Phase 4 dataset missing"; return; }
    local size_mb=$(awk -v b=$(wc -c < "$file") 'BEGIN{printf "%.2f", b/1048576}')
    echo "[$MODE] aggregation input=${size_mb} MB"

    run_for_mode "p4_lp_${MODE}" -- bash -c "\"$LOG_PARSE\" --regex '^type=clip duration=([0-9]+)$' --fields dur --sum dur < \"$file\" > test_env/lp_agg.out"
    local lp_rss=$(read_rss_kb "$LOG_DIR/p4_lp_${MODE}.rusage")
    local lp_tp=$(mb_per_s "$size_mb" "$WALL")
    echo "    log_parse --sum   ${lp_tp} MB/s  wall=${WALL}s  rss=${lp_rss}kB"
    csv_row 4 "$MODE" log_parse_sum "$size_mb" "$WALL" "$lp_tp" 0 "$lp_rss" "B-class:main"

    run_for_mode "p4_awk_${MODE}" -- bash -c "awk 'match(\$0,/^type=clip duration=([0-9]+)\$/,a){sum+=a[1]} END{print sum}' \"$file\" > test_env/awk_agg.out"
    local awk_rss=$(read_rss_kb "$LOG_DIR/p4_awk_${MODE}.rusage")
    local awk_tp=$(mb_per_s "$size_mb" "$WALL")
    echo "    awk match()       ${awk_tp} MB/s  wall=${WALL}s  rss=${awk_rss}kB"
    csv_row 4 "$MODE" gnu_awk_match "$size_mb" "$WALL" "$awk_tp" 0 "$awk_rss" "B-class:main"
}
if want_phase 4; then banner "Phase 4: log_parse --sum vs awk match()"; for_each_mode phase4_body; fi

phase5_body() {
    local file="test_env/bench_clip_store.jsonl"
    [ -f "$file" ] || { echo "Phase 5 dataset missing"; return; }
    local size_mb=$(awk -v b=$(wc -c < "$file") 'BEGIN{printf "%.2f", b/1048576}')
    echo "[$MODE] clip_store ingest, input=${size_mb} MB"

    : > test_env/clip_store_${MODE}.db   # truncate (rm may fail on shared-mount files)
    run_for_mode "p5_cs_${MODE}" -- bash -c "set -o pipefail; \"$LOG_PARSE\" --filter type=clip < \"$file\" | \"$CLIP_STORE\" --db test_env/clip_store_${MODE}.db --ttl 0"
    local cs_rss=$(read_rss_kb "$LOG_DIR/p5_cs_${MODE}.rusage")
    local cs_tp=$(mb_per_s "$size_mb" "$WALL")
    local cs_db_mb=$(awk -v b=$(wc -c < test_env/clip_store_${MODE}.db 2>/dev/null || echo 0) 'BEGIN{printf "%.2f", b/1048576}')
    echo "    clip_store        ${cs_tp} MB/s  wall=${WALL}s  rss=${cs_rss}kB  db=${cs_db_mb}MB"
    csv_row 5 "$MODE" clip_store "$size_mb" "$WALL" "$cs_tp" "$cs_db_mb" "$cs_rss" "C-class:main"

    rm -f test_env/awk_gzip_${MODE}.gz
    run_for_mode "p5_awkgz_${MODE}" -- bash -c "awk -v now=\$(date +%s) '{print \"sess:\" NR \"\\t\" \$0 \"\\t\" now+300}' \"$file\" | gzip > test_env/awk_gzip_${MODE}.gz"
    local agz_rss=$(read_rss_kb "$LOG_DIR/p5_awkgz_${MODE}.rusage")
    local agz_tp=$(mb_per_s "$size_mb" "$WALL")
    local agz_db_mb=$(awk -v b=$(wc -c < test_env/awk_gzip_${MODE}.gz 2>/dev/null || echo 0) 'BEGIN{printf "%.2f", b/1048576}')
    echo "    awk + gzip        ${agz_tp} MB/s  wall=${WALL}s  rss=${agz_rss}kB  db=${agz_db_mb}MB"
    csv_row 5 "$MODE" awk_gzip "$size_mb" "$WALL" "$agz_tp" "$agz_db_mb" "$agz_rss" "C-class:main"
}
if want_phase 5; then banner "Phase 5: clip_store ingest vs awk+gzip"; for_each_mode phase5_body; fi

phase6_body() {
    local file="test_env/bench_medium.bin"
    [ -f "$file" ] || { echo "Phase 6 dataset missing"; return; }
    local size_mb=$(awk -v b=$(wc -c < "$file") 'BEGIN{printf "%.2f", b/1048576}')
    echo "[$MODE] E2E on ${size_mb} MB"

    : > test_env/e2e_${MODE}_dispatcher.db
    run_for_mode "p6_disp_${MODE}" -- "$PIPELINE_DISPATCHER" --ttl 0 bench_medium test_env test_env/e2e_${MODE}_dispatcher.db
    local disp_clips=$(wc -l < test_env/e2e_${MODE}_dispatcher.db 2>/dev/null || echo 0)
    local disp_rss=$(read_rss_kb "$LOG_DIR/p6_disp_${MODE}.rusage")
    local disp_tp=$(mb_per_s "$size_mb" "$WALL")
    echo "    pipeline_dispatcher ${disp_tp} MB/s  wall=${WALL}s  clips=${disp_clips}  rss=${disp_rss}kB"
    csv_row 6 "$MODE" pipeline_dispatcher "$size_mb" "$WALL" "$disp_tp" "$disp_clips" "$disp_rss" "C-class:main"

    : > test_env/e2e_${MODE}_shellpipe.db
    run_for_mode "p6_shell_${MODE}" -- bash -c "set -o pipefail; \"$STREAM_MERGE\" bench_medium test_env | \"$LOG_PARSE\" --filter type=clip | \"$CLIP_STORE\" --db test_env/e2e_${MODE}_shellpipe.db --ttl 0"
    local sh_clips=$(wc -l < test_env/e2e_${MODE}_shellpipe.db 2>/dev/null || echo 0)
    local sh_rss=$(read_rss_kb "$LOG_DIR/p6_shell_${MODE}.rusage")
    local sh_tp=$(mb_per_s "$size_mb" "$WALL")
    echo "    shell pipe          ${sh_tp} MB/s  wall=${WALL}s  clips=${sh_clips}  rss=${sh_rss}kB"
    csv_row 6 "$MODE" shell_pipe "$size_mb" "$WALL" "$sh_tp" "$sh_clips" "$sh_rss" "C-class:main"
}
if want_phase 6; then banner "Phase 6: pipeline_dispatcher vs shell pipe"; for_each_mode phase6_body; fi

phase7_body() {
    [ "$MODE" = "constrained" ] || return
    local file="test_env/stress_big.jsonl"
    if [ ! -f "$file" ]; then
        python3 - <<'PYBIG'
import json
with open("test_env/stress_big.jsonl","w") as f:
    rec = {"type":"clip","payload":"x"*500,"i":0}
    for i in range(100000):
        rec["i"]=i
        f.write(json.dumps(rec, separators=(',',':')) + "\n")
PYBIG
    fi
    local size_mb=$(awk -v b=$(wc -c < "$file") 'BEGIN{printf "%.2f", b/1048576}')
    echo "[constrained] stress test on ${size_mb} MB"
    if [ "$LIMIT_MODE" = "prlimit-taskset" ]; then
        echo "    WARNING: limit mode = prlimit-taskset; --as limits virtual address space, NOT RSS."
        echo "             A 'PASS' here may NOT correspond to passing under cgroup MemoryMax."
        echo "             Re-run on a host with systemd-run --user (cgroup v2) for the real OOM signal."
    elif [ "$LIMIT_MODE" = "none" ]; then
        echo "    WARNING: no resource limit active; stress test is informational only."
    fi

    if time_run run_constrained "p7_lp" -- bash -c "\"$LOG_PARSE\" --filter type=clip < \"$file\" > /dev/null"; then
        local lp_rss=$(read_rss_kb "$LOG_DIR/p7_lp.rusage")
        local lp_tp=$(mb_per_s "$size_mb" "$WALL")
        echo "    log_parse stream    PASS  ${lp_tp} MB/s  rss=${lp_rss}kB"
        csv_row 7 constrained log_parse_stream "$size_mb" "$WALL" "$lp_tp" 0 "$lp_rss" "stress-pass"
    else
        echo "    log_parse stream    FAIL exit=$?"
        csv_row 7 constrained log_parse_stream "$size_mb" "$WALL" 0 0 0 "stress-FAILED"
    fi

    if time_run run_constrained "p7_jq_slurp" -- bash -c "jq -s 'map(select(.type==\"clip\")) | length' \"$file\" > /dev/null"; then
        local jq_rss=$(read_rss_kb "$LOG_DIR/p7_jq_slurp.rusage")
        local jq_tp=$(mb_per_s "$size_mb" "$WALL")
        echo "    jq -s (slurp)       PASS  ${jq_tp} MB/s  rss=${jq_rss}kB"
        csv_row 7 constrained jq_slurp "$size_mb" "$WALL" "$jq_tp" 0 "$jq_rss" "stress-pass"
    else
        local jq_exit=$?
        echo "    jq -s (slurp)       FAIL exit=$jq_exit  (likely OOM at MemoryMax=${MEM_LIMIT_MB}M)"
        csv_row 7 constrained jq_slurp "$size_mb" "$WALL" 0 0 0 "stress-OOM-exit-$jq_exit"
    fi

    if time_run run_constrained "p7_jq_stream" -- bash -c "jq -c --stream 'select(.[0][-1]==\"type\" and .[1]==\"clip\")' \"$file\" > /dev/null"; then
        local jqs_rss=$(read_rss_kb "$LOG_DIR/p7_jq_stream.rusage")
        local jqs_tp=$(mb_per_s "$size_mb" "$WALL")
        echo "    jq --stream         PASS  ${jqs_tp} MB/s  rss=${jqs_rss}kB"
        csv_row 7 constrained jq_stream "$size_mb" "$WALL" "$jqs_tp" 0 "$jqs_rss" "stress-pass"
    else
        echo "    jq --stream         FAIL exit=$?"
        csv_row 7 constrained jq_stream "$size_mb" "$WALL" 0 0 0 "stress-FAILED"
    fi
}
if want_phase 7; then banner "Phase 7: Stress test — memory ceiling behaviour"; for_each_mode phase7_body; fi

banner "Done"
echo "Results CSV:  $CSV"
echo "Logs:         $LOG_DIR"
echo
column -t -s, "$CSV" | head -80
