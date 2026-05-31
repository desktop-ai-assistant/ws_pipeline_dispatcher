#!/bin/sh
set -eu

LOG_PARSE=${LOG_PARSE:-./.build/log_parse}
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

check_eq() {
    name=$1
    expected=$2
    actual=$3
    if [ "$expected" != "$actual" ]; then
        printf 'FAIL %s\nexpected: %s\nactual:   %s\n' "$name" "$expected" "$actual" >&2
        exit 1
    fi
}

check_exit() {
    name=$1
    expected=$2
    shift 2
    set +e
    "$@" >"$TMP_DIR/$name.out" 2>"$TMP_DIR/$name.err"
    actual=$?
    set -e
    check_eq "$name exit" "$expected" "$actual"
}

printf '  1747065600 clip /tmp/clips/sess_001/1747065600.mp4  \n' |
    "$LOG_PARSE" --regex '^([0-9]+) ([a-z_]+) (.+)$' --fields ts,type,path --format json --filter type=clip \
    >"$TMP_DIR/json.out" 2>"$TMP_DIR/json.err"
check_eq "regex json output" \
    '{"ts":"1747065600","type":"clip","path":"/tmp/clips/sess_001/1747065600.mp4"}' \
    "$(cat "$TMP_DIR/json.out")"
check_eq "regex json stderr" "" "$(cat "$TMP_DIR/json.err")"

printf '1747065600 clip /tmp/clips/sess_001/1747065600.mp4\n' |
    "$LOG_PARSE" --regex '^([0-9]+) ([a-z_]+) (.+)$' --fields ts,type,path --format csv --filter type=clip \
    >"$TMP_DIR/csv.out" 2>"$TMP_DIR/csv.err"
check_eq "regex csv output" \
    '1747065600,clip,/tmp/clips/sess_001/1747065600.mp4' \
    "$(cat "$TMP_DIR/csv.out")"
check_eq "regex csv stderr" "" "$(cat "$TMP_DIR/csv.err")"

printf '1747065601 heartbeat /tmp/heartbeat\n' |
    "$LOG_PARSE" --regex '^([0-9]+) ([a-z_]+) (.+)$' --fields ts,type,path --format json --filter type=clip \
    >"$TMP_DIR/drop.out" 2>"$TMP_DIR/drop.err"
check_eq "regex filter drop stdout" "" "$(cat "$TMP_DIR/drop.out")"
check_eq "regex filter drop stderr" "" "$(cat "$TMP_DIR/drop.err")"

printf '1747065601 heartbeat /tmp/heartbeat\n1747065602 clip /tmp/clips/a.mp4\n' |
    "$LOG_PARSE" --regex '^([0-9]+) ([a-z_]+) (.+)$' --fields ts,type,path --format json --filter 'type!=heartbeat' \
    >"$TMP_DIR/regex_ne.out" 2>"$TMP_DIR/regex_ne.err"
check_eq "regex != output" \
    '{"ts":"1747065602","type":"clip","path":"/tmp/clips/a.mp4"}' \
    "$(cat "$TMP_DIR/regex_ne.out")"
check_eq "regex != stderr" "" "$(cat "$TMP_DIR/regex_ne.err")"

printf '1747065601 heartbeat /tmp/heartbeat\n1747065602 clip /tmp/clips/a.mp4\n' |
    "$LOG_PARSE" --regex '^([0-9]+) ([a-z_]+) (.+)$' --fields ts,type,path --build-full-log "$TMP_DIR/full.log" --filter type=clip \
    >"$TMP_DIR/full_stdout.out" 2>"$TMP_DIR/full_stderr.err"
check_eq "full log stdout filtered" \
    '{"ts":"1747065602","type":"clip","path":"/tmp/clips/a.mp4"}' \
    "$(cat "$TMP_DIR/full_stdout.out")"
check_eq "full log captures all parsed records" \
    '{"ts":"1747065601","type":"heartbeat","path":"/tmp/heartbeat"}
{"ts":"1747065602","type":"clip","path":"/tmp/clips/a.mp4"}' \
    "$(cat "$TMP_DIR/full.log")"
check_eq "full log stderr" "" "$(cat "$TMP_DIR/full_stderr.err")"

printf '1747065600 clip old\n1747065602 clip new\n' |
    "$LOG_PARSE" --regex '^([0-9]+) ([a-z_]+) (.+)$' --fields ts,type,msg --format csv --filter 'ts>1747065600' \
    >"$TMP_DIR/regex_gt.out" 2>"$TMP_DIR/regex_gt.err"
check_eq "regex > output" '1747065602,clip,new' "$(cat "$TMP_DIR/regex_gt.out")"
check_eq "regex > stderr" "" "$(cat "$TMP_DIR/regex_gt.err")"

printf '1747065600 clip /tmp/clips/a.mp4\n1747065601 clip /tmp/tmpfile\n' |
    "$LOG_PARSE" --regex '^([0-9]+) ([a-z_]+) (.+)$' --fields ts,type,path --format count --filter 'path~/clips/' \
    >"$TMP_DIR/regex_count.out" 2>"$TMP_DIR/regex_count.err"
check_eq "regex contains count output" '1' "$(cat "$TMP_DIR/regex_count.out")"
check_eq "regex contains count stderr" "" "$(cat "$TMP_DIR/regex_count.err")"

printf 'bad line\n' |
    "$LOG_PARSE" --regex '^([0-9]+) ([a-z_]+) (.+)$' --fields ts,type,path --format json \
    >"$TMP_DIR/regex_bad.out" 2>"$TMP_DIR/regex_bad.err"
check_eq "regex bad stdout" "" "$(cat "$TMP_DIR/regex_bad.out")"
if ! grep 'line did not match regex' "$TMP_DIR/regex_bad.err" >/dev/null 2>&1; then
    printf 'FAIL regex bad stderr missing warning\n' >&2
    exit 1
fi

printf '1747065600 clip alpha,"beta"\n' |
    "$LOG_PARSE" --regex '^([0-9]+) ([a-z_]+) (.+)$' --fields ts,type,msg --format csv \
    >"$TMP_DIR/csv_quote.out" 2>"$TMP_DIR/csv_quote.err"
check_eq "csv quoted output" \
    '1747065600,clip,"alpha,""beta"""' \
    "$(cat "$TMP_DIR/csv_quote.out")"
check_eq "csv quoted stderr" "" "$(cat "$TMP_DIR/csv_quote.err")"

printf '1747065600 clip path="C:\\tmp\\clip"\n' |
    "$LOG_PARSE" --regex '^([0-9]+) ([a-z_]+) (.+)$' --fields ts,type,msg --format json \
    >"$TMP_DIR/json_escape.out" 2>"$TMP_DIR/json_escape.err"
check_eq "json escaped output" \
    '{"ts":"1747065600","type":"clip","msg":"path=\"C:\\tmp\\clip\""}' \
    "$(cat "$TMP_DIR/json_escape.out")"
check_eq "json escaped stderr" "" "$(cat "$TMP_DIR/json_escape.err")"

{
    printf '  {"type":"clip","session_id":"sess_001","ts":1747065600,"path":"/tmp/clips/sess_001/1747065600.mp4"}  \n'
    printf '{"type":"heartbeat","session_id":"sess_001","ts":1747065601}\n'
} | "$LOG_PARSE" --filter type=clip >"$TMP_DIR/integration.out" 2>"$TMP_DIR/integration.err"
check_eq "integration clip pass-through" \
    '{"type":"clip","session_id":"sess_001","ts":1747065600,"path":"/tmp/clips/sess_001/1747065600.mp4"}' \
    "$(cat "$TMP_DIR/integration.out")"
check_eq "integration stderr" "" "$(cat "$TMP_DIR/integration.err")"

{
    printf '{"type":"clip","session_id":"sess_001","ts":1747065600,"path":"/tmp/clips/a.mp4","complete":true}\n'
    printf '{"type":"heartbeat","session_id":"sess_001","ts":1747065601,"path":"/tmp/tmpfile","complete":false}\n'
    printf '{"type":"clip","session_id":"sess_002","ts":1747065602,"path":"/tmp/clips/b.mp4","complete":true}\n'
} | "$LOG_PARSE" --filter 'type!=heartbeat' --format count >"$TMP_DIR/json_ne_count.out" 2>"$TMP_DIR/json_ne_count.err"
check_eq "json != count output" '2' "$(cat "$TMP_DIR/json_ne_count.out")"
check_eq "json != count stderr" "" "$(cat "$TMP_DIR/json_ne_count.err")"

{
    printf '{"type":"clip","ts":1747065600,"path":"/tmp/clips/a.mp4","complete":true}\n'
    printf '{"type":"clip","ts":1747065602,"path":"/tmp/tmpfile","complete":false}\n'
} | "$LOG_PARSE" --filter 'ts>1747065600' >"$TMP_DIR/json_gt.out" 2>"$TMP_DIR/json_gt.err"
check_eq "json > pass-through" \
    '{"type":"clip","ts":1747065602,"path":"/tmp/tmpfile","complete":false}' \
    "$(cat "$TMP_DIR/json_gt.out")"
check_eq "json > stderr" "" "$(cat "$TMP_DIR/json_gt.err")"

{
    printf '{"path":"/tmp/clips/a.mp4","complete":true}\n'
    printf '{"path":"/tmp/tmpfile","complete":false}\n'
} | "$LOG_PARSE" --filter 'path~/clips/' >"$TMP_DIR/json_contains.out" 2>"$TMP_DIR/json_contains.err"
check_eq "json contains pass-through" '{"path":"/tmp/clips/a.mp4","complete":true}' "$(cat "$TMP_DIR/json_contains.out")"
check_eq "json contains stderr" "" "$(cat "$TMP_DIR/json_contains.err")"

{
    printf '{"complete":true}\n'
    printf '{"complete":false}\n'
} | "$LOG_PARSE" --filter complete=true --format count >"$TMP_DIR/json_bool_count.out" 2>"$TMP_DIR/json_bool_count.err"
check_eq "json bool count output" '1' "$(cat "$TMP_DIR/json_bool_count.out")"
check_eq "json bool count stderr" "" "$(cat "$TMP_DIR/json_bool_count.err")"

printf 'not json\n' | "$LOG_PARSE" --filter type=clip >"$TMP_DIR/bad.out" 2>"$TMP_DIR/bad.err"
check_eq "bad json stdout" "" "$(cat "$TMP_DIR/bad.out")"
if ! grep 'malformed JSON line' "$TMP_DIR/bad.err" >/dev/null 2>&1; then
    printf 'FAIL bad json stderr missing warning\n' >&2
    exit 1
fi

check_exit invalid_filter 1 "$LOG_PARSE" --filter type
if ! grep 'invalid filter syntax' "$TMP_DIR/invalid_filter.err" >/dev/null 2>&1; then
    printf 'FAIL invalid filter stderr missing error\n' >&2
    exit 1
fi

check_exit invalid_format 1 "$LOG_PARSE" --regex '^(.+)$' --fields msg --format xml
if ! grep 'unsupported format=xml' "$TMP_DIR/invalid_format.err" >/dev/null 2>&1; then
    printf 'FAIL invalid format stderr missing error\n' >&2
    exit 1
fi

check_exit missing_fields 1 "$LOG_PARSE" --regex '^(.+)$'
if ! grep -- '--fields is required with --regex' "$TMP_DIR/missing_fields.err" >/dev/null 2>&1; then
    printf 'FAIL missing fields stderr missing error\n' >&2
    exit 1
fi

check_exit csv_without_regex 1 "$LOG_PARSE" --format csv
if ! grep -- '--fields and --format json|csv require --regex' "$TMP_DIR/csv_without_regex.err" >/dev/null 2>&1; then
    printf 'FAIL csv without regex stderr missing error\n' >&2
    exit 1
fi

printf 'OK: all log_parse tests passed\n'
