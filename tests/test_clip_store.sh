#!/bin/sh
set -eu

CLIP_STORE=${CLIP_STORE:-./.build/clip_store}
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
DB="$TMP_DIR/clips.db"

check_eq() {
    name=$1
    expected=$2
    actual=$3
    if [ "$expected" != "$actual" ]; then
        printf 'FAIL %s\nexpected: %s\nactual:   %s\n' "$name" "$expected" "$actual" >&2
        exit 1
    fi
}

clip_one='{"type":"clip","session_id":"sess_001","ts":1747065600,"path":"/tmp/one.mp4"}'
clip_two='{"type":"clip","session_id":"sess_001","ts":1747065600,"path":"/tmp/two.mp4"}'
clip_no_expire='{"type":"clip","session_id":"sess_001","ts":1747065601,"path":"/tmp/no_expire.mp4"}'

printf '%s\n' "$clip_one" |
    "$CLIP_STORE" --db "$DB" --ttl 300 >"$TMP_DIR/write.out" 2>"$TMP_DIR/write.err"
check_eq "pipe write stdout" "" "$(cat "$TMP_DIR/write.out")"
check_eq "pipe write get" "$clip_one" "$("$CLIP_STORE" --db "$DB" --get sess_001:1747065600)"

printf '%s\n' "$clip_two" |
    "$CLIP_STORE" --db "$DB" --ttl 300
check_eq "upsert latest value" "$clip_two" "$("$CLIP_STORE" --db "$DB" --get sess_001:1747065600)"

printf '%s\n' "$clip_no_expire" |
    "$CLIP_STORE" --db "$DB" --ttl 0
check_eq "ttl=0 never expires get" "$clip_no_expire" "$("$CLIP_STORE" --db "$DB" --get sess_001:1747065601)"

"$CLIP_STORE" --db "$DB" --set sess_002:1=/tmp/set.mp4
check_eq "set get" "/tmp/set.mp4" "$("$CLIP_STORE" --db "$DB" --get sess_002:1)"

check_eq "prefix list" "sess_001:1747065600	$clip_two
sess_001:1747065601	$clip_no_expire" "$("$CLIP_STORE" --db "$DB" --prefix sess_001: | sort)"

check_eq "list includes set" "sess_002:1	/tmp/set.mp4" "$("$CLIP_STORE" --db "$DB" --list | grep '^sess_002:1')"

"$CLIP_STORE" --db "$DB" --delete sess_002:1
check_eq "delete tombstone get empty" "" "$("$CLIP_STORE" --db "$DB" --get sess_002:1)"
check_eq "delete hides from list" "" "$("$CLIP_STORE" --db "$DB" --list | grep '^sess_002:1' || true)"

"$CLIP_STORE" --db "$DB" --gc
check_eq "gc removes duplicates, keeps never-expire rows" "2" "$(wc -l <"$DB" | tr -d ' ')"
check_eq "gc keeps latest for sess_001:1747065600" "$clip_two" "$("$CLIP_STORE" --db "$DB" --get sess_001:1747065600)"
check_eq "gc keeps never-expire row" "$clip_no_expire" "$("$CLIP_STORE" --db "$DB" --get sess_001:1747065601)"

for i in 1 2 3 4 5; do
    (printf '{"type":"clip","session_id":"sess_c","ts":%s,"path":"/tmp/%s.mp4"}\n' "$i" "$i" |
        "$CLIP_STORE" --db "$DB" --ttl 300) &
done
wait
"$CLIP_STORE" --db "$DB" --gc
check_eq "concurrent writes line count" "7" "$(wc -l <"$DB" | tr -d ' ')"

HASH_DB="$TMP_DIR/hash-grow.db"
for i in $(seq 1 80); do
    "$CLIP_STORE" --db "$HASH_DB" --ttl 0 --set "grow:$i=/tmp/grow_$i.mp4"
done
check_eq "hash index grows list count" "80" "$("$CLIP_STORE" --db "$HASH_DB" --list | wc -l | tr -d ' ')"
check_eq "hash index grows get latest" "/tmp/grow_80.mp4" "$("$CLIP_STORE" --db "$HASH_DB" --get grow:80)"
"$CLIP_STORE" --db "$HASH_DB" --compact
check_eq "hash index grows compact count" "80" "$(wc -l <"$HASH_DB" | tr -d ' ')"

printf 'OK: all clip_store tests passed\n'
