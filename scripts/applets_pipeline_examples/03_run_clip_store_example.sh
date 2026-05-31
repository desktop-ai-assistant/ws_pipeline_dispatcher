#!/bin/bash
set -e

# Change to the root of the workspace
WORKSPACE_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$WORKSPACE_ROOT"

# Ensure the binary is built
make .build/clip_store > /dev/null

echo "========================================================="
echo " Example 03: clip_store"
echo "========================================================="
echo " The 'clip_store' applet reads filtered JSON log records"
echo " from stdin (typically from log_parse) and saves them"
echo " into a compact database file using a simple TSV format."
echo " Values are complete JSON records compressed with zlib/base64."
echo " It automatically cleans up expired entries (TTL)."
echo "========================================================="
echo ""

DB_PATH=$(mktemp)

echo "[1] Creating an empty temporary database at: $DB_PATH"
echo ""

echo "[2] Simulating incoming JSON clip records (from stdin)"
echo "Command:"
echo "  ./.build/clip_store --db \"$DB_PATH\" --ttl 300"
echo ""

# Feed some JSON clip records to clip_store
cat << 'EOF' | ./.build/clip_store --db "$DB_PATH" --ttl 300
{"session_id":"sess_A","ts":1000,"type":"clip","duration":5,"path":"/tmp/sess_A_1.bin"}
{"session_id":"sess_A","ts":6000,"type":"clip","duration":5,"path":"/tmp/sess_A_2.bin"}
EOF

echo "[3] Database contents after first run:"
cat "$DB_PATH"
echo ""

echo "[4] Updating an existing record (ts=1000)"
# clip_store automatically uses session_id:ts as the key, e.g., sess_A:1000
# We will simulate an update where the duration changed or completed flag was added
cat << 'EOF' | ./.build/clip_store --db "$DB_PATH" --ttl 300
{"session_id":"sess_A","ts":1000,"type":"clip","duration":6,"path":"/tmp/sess_A_1.bin","complete":true}
EOF

echo ""
echo "[5] Database contents after update (notice the append-only nature):"
cat "$DB_PATH"
echo ""
echo "(Note: During garbage collection/compaction, the old row for sess_A:1000 will be removed.)"
echo ""

echo "Cleaning up..."
rm -f "$DB_PATH"
echo "Done!"
