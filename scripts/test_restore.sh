#!/usr/bin/env bash
# Proves the backup actually restores. Run this against a SCRATCH database,
# never production, and capture its output as your DR test evidence
# (paste the output into docs/dr-runbook.md's "Test Restore Evidence" section
# or redirect it: ./scripts/test_restore.sh | tee docs/evidence/restore-$(date +%F).log)
#
# Usage: bash scripts/test_restore.sh <path-to-backup.sql.gz> <db-host> <ssh-port>
set -euo pipefail

BACKUP_FILE="${1:?Usage: test_restore.sh <backup.sql.gz> <db-host> [ssh-port]}"
DB_HOST="${2:?Usage: test_restore.sh <backup.sql.gz> <db-host> [ssh-port]}"
SSH_PORT="${3:-22}"
SCRATCH_DB="swiftpay_restore_test_$(date +%s)"

echo "=== SwiftPay DR test-restore ==="
echo "Backup file : $BACKUP_FILE"
echo "Target host : $DB_HOST"
echo "Scratch DB  : $SCRATCH_DB"
echo "Started at  : $(date -u)"
echo ""

echo "[1/4] Creating scratch database..."
ssh -p "$SSH_PORT" ansible@"$DB_HOST" "sudo -u postgres createdb $SCRATCH_DB"

echo "[2/4] Copying backup file to target..."
scp -P "$SSH_PORT" "$BACKUP_FILE" ansible@"$DB_HOST":/tmp/restore_test.sql.gz

echo "[3/4] Restoring into scratch database..."
ssh -p "$SSH_PORT" ansible@"$DB_HOST" \
  "gunzip -c /tmp/restore_test.sql.gz | sudo -u postgres psql $SCRATCH_DB"

echo "[4/4] Verifying row counts..."
ssh -p "$SSH_PORT" ansible@"$DB_HOST" \
  "sudo -u postgres psql $SCRATCH_DB -c 'SELECT count(*) AS accounts_restored FROM accounts;'"

echo ""
echo "[cleanup] Dropping scratch database and temp file..."
ssh -p "$SSH_PORT" ansible@"$DB_HOST" "sudo -u postgres dropdb $SCRATCH_DB && rm -f /tmp/restore_test.sql.gz"

echo ""
echo "Finished at : $(date -u)"
echo "=== Result: PASS if accounts_restored > 0 above, and no errors in [3/4] ==="
