# Disaster Recovery Runbook — SwiftPay Portal

## Targets

| Metric | Target | Basis |
|---|---|---|
| **RPO** (Recovery Point Objective) | ≤ 24 hours | Backups run nightly at 02:15 via `swiftpay-backup.timer`. If more frequent RPO is needed, drop the timer to hourly — one-line change in `roles/backup/templates/swiftpay-backup.timer.j2`. |
| **RTO** (Recovery Time Objective) | ≤ 1 hour | Time to: provision/repair a DB host, restore latest dump, repoint app tier — see step-by-step below. Streaming replica promotion (if primary dies but replica lives) is much faster, ≤ 10 minutes. |

## Scenario A — Primary DB host dies, replica is healthy (fast path)

1. On `db2` (replica), promote it to primary:
   ```bash
   sudo -u postgres pg_ctl promote -D /var/lib/postgresql/16/main
   ```
2. Update `group_vars/all/vars.yml` / inventory so `db2` is now `pg_role=primary`,
   and re-run the `appserver` role so `swiftpay.env` points app tier at the
   new primary's `internal_ip`:
   ```bash
   ansible-playbook -i inventory/hosts.ini site.yml --limit app --ask-vault-pass
   ```
3. Rebuild a new replica from the new primary once a replacement host exists
   (re-run the `database` role against the new host with `pg_role=replica`).
4. Verify: `curl http://<app-host>:8000/healthz` and a `/balance/1` call succeed.

**Estimated RTO: 10–20 minutes** (mostly the Ansible re-run + verification).

## Scenario B — Total data loss, restoring from backup (full path)

1. Provision a replacement DB host (Docker container locally, or
   `scripts/aws_provision.sh` pattern for a single instance on AWS).
2. Run the `common`, `security`, `firewall`, `database` roles against it so
   PostgreSQL is installed and configured identically:
   ```bash
   ansible-playbook -i inventory/hosts.ini site.yml --limit db1
   ```
3. Copy the latest backup from the off-host copy (on `lb1` in the lab, or S3
   in prod) to the new DB host:
   ```bash
   scp -P 2201 ansible@127.0.0.1:/var/backups/swiftpay-offsite/swiftpay-<latest>.sql.gz .
   scp -P 2231 swiftpay-<latest>.sql.gz ansible@127.0.0.1:/tmp/
   ```
4. Restore:
   ```bash
   ssh -p 2231 ansible@127.0.0.1 \
     "gunzip -c /tmp/swiftpay-<latest>.sql.gz | sudo -u postgres psql swiftpay"
   ```
5. Verify row counts match expectations, then re-run the `appserver` role so
   the app tier reconnects.

**Estimated RTO: 30–45 minutes** including host provisioning.

## Test-restore evidence (required — a backup you've never restored is a guess)

Run `scripts/test_restore.sh` against a **scratch database**, never
production, and capture the output here (or in `docs/evidence/`):

```
$ bash scripts/test_restore.sh swiftpay-20260830-021500.sql.gz 127.0.0.1 2231
=== SwiftPay DR test-restore ===
...
[4/4] Verifying row counts...
 accounts_restored
--------------------
                  1
(1 row)
=== Result: PASS if accounts_restored > 0 above, and no errors in [3/4] ===
```

> Paste your own real run's output here before submission — this is the
> "evidence" the brief explicitly asks for, not just the runbook text.

## What's backed up

- Full `pg_dump` of the `swiftpay` database (nightly, `roles/backup`)
- `/etc/postgresql` config tree (pg_hba.conf, postgresql.conf) — helps
  reconstruct access rules even without the Ansible repo to hand
- The Ansible repo itself (in Git) is the backup for *everything else* —
  web/app/lb config is 100% reconstructible by re-running `site.yml`, so it
  is deliberately **not** included in the data backup.

## Backup retention

14 days locally on `db1`, rotated by `find -mtime +14 -delete` in the backup
script. Off-host copies on `lb1` are not currently rotated — a known gap,
noted so it isn't silently forgotten (see `docs/architecture.md` "next steps").
