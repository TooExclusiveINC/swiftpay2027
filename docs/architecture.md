# SwiftPay Portal — Architecture Document

## 1. Topology

```
                         Internet
                            │
                     ┌──────▼──────┐
                     │   lb1       │  HAProxy, TLS termination
                     │  (public)   │  :80 -> redirect -> :443
                     └──────┬──────┘
                 ┌──────────┴──────────┐
           ┌─────▼─────┐         ┌─────▼─────┐
           │   web1    │         │   web2    │   Nginx, reverse proxy
           └─────┬─────┘         └─────┬─────┘   to app tier, /healthz
                 └──────────┬──────────┘
                 ┌──────────┴──────────┐
           ┌─────▼─────┐         ┌─────▼─────┐
           │   app1    │         │   app2    │   Flask/gunicorn, systemd,
           └─────┬─────┘         └─────┬─────┘   dedicated service account
                 └──────────┬──────────┘
                 ┌──────────┴──────────┐
           ┌─────▼─────┐  streaming  ┌─▼─────────┐
           │    db1    │────────────▶│    db2    │  PostgreSQL
           │ (primary) │  replication│ (replica) │  primary + hot standby
           └───────────┘             └───────────┘
```

Every arrow above is also a firewall rule (ufw locally / security groups on
AWS) — not just an application-level assumption. See `roles/firewall/tasks/main.yml`.

## 2. Design decisions

| Decision | Why | Alternative considered |
|---|---|---|
| Ubuntu 22.04 everywhere | One free-tier-eligible AMI family, consistent AppArmor tooling, simpler Ansible (`apt` everywhere) | RHEL-family for SELinux — rejected to avoid mixed package managers across only 7 hosts on a 1-day build budget |
| Nginx (web tier) | Simple, well-understood reverse-proxy config; low resource footprint for t2.micro | Apache — equally valid, more modules than needed here |
| HAProxy (LB) | Purpose-built L4/L7 balancer, first-class active health checks, stats page for the demo | Nginx-as-LB — works, but HAProxy's health-check semantics are clearer for the failover demo |
| PostgreSQL streaming replication | Built-in, well-documented, `pg_basebackup` + `standby.signal` is a small amount of moving parts | MySQL/MariaDB replication — equally valid; Postgres chosen for team familiarity |
| Ansible only, no Terraform | Brief explicitly asked for manual provisioning via CLI + Ansible for config; Terraform listed as optional/rewarded but out of scope for the 1-day build | Terraform — noted as a "next" improvement below |
| 7 hosts, not 4–6 | Tier isolation requirement (web/app/db must be separate hosts) plus 2x redundancy on web+app plus a DB pair; combining tiers on one host would blur the boundary the brief asks us to enforce | Collapsing web+app onto shared hosts — rejected, defeats the point of proving tier isolation |
| Every host gets a public IP on AWS | A NAT gateway (needed for a "real" private-subnet design) is not free-tier eligible (~$0.045/hr) | Private subnets + NAT — the more correct production pattern, deferred to stay in free tier; security groups are the actual isolation boundary in this build |

## 3. Single points of failure

| SPOF | Addressed? | Reasoning |
|---|---|---|
| `lb1` (single HAProxy node) | **Accepted, not addressed** | A second HAProxy + keepalived VIP needs a floating IP, which either costs money (AWS EIP reassignment scripting) or requires an ELB (not "manual provisioning" in spirit of the brief). Documented here as the honest remaining gap. |
| Single AWS Availability Zone | **Accepted, not addressed** | Multi-AZ needs a NAT gateway per AZ or a more complex routing setup — out of scope for a free-tier 1-day build. |
| DB failover is manual | **Partially addressed** | Streaming replication gives us a warm standby; promotion (`pg_ctl promote` / `touch standby.signal` removal) is a documented manual runbook step, not automatic failover (would need Patroni/repmgr — a good "next" improvement). |
| Web tier node loss | **Addressed** | HAProxy health-checks `/healthz` every 2s and routes around a dead web node — demoed live by stopping one container/instance. |
| App tier node loss | **Addressed** | Nginx upstream block lists both app nodes with `max_fails`/`fail_timeout`, so a dead app node is skipped within seconds. |
| Backup single-copy | **Addressed** | Nightly backups are rsynced off the DB host to `lb1` (stand-in for S3 in the lab); production should point at S3 directly (one-line change, see `roles/backup/templates/backup.sh.j2`). |

## 4. What would come next (stretch goals, not required)
- Terraform for the EC2/VPC provisioning layer (currently a bash script)
- Patroni or repmgr for automatic Postgres failover
- A second HAProxy + keepalived to remove the LB SPOF
- Full Prometheus + Grafana stack scraping the node_exporter endpoints already installed on every host
