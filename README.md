# SwiftPay Portal — Production Infrastructure

A hardened, automated, monitored, highly-available multi-tier stack for SwiftPay
Technologies, built with Ansible. No Terraform — hosts are provisioned manually
(Docker containers for local testing, `aws` CLI commands for the real build),
and Ansible does 100% of the configuration.

## Architecture (7 hosts, justified below 6-VM guideline)

| Host        | Role                                  | Tier   |
|-------------|----------------------------------------|--------|
| `lb1`       | HAProxy, TLS termination, health checks | Edge   |
| `web1/web2` | Nginx — static assets + reverse proxy   | Web    |
| `app1/app2` | Flask app (systemd service, port 8000)  | App    |
| `db1`       | PostgreSQL primary                      | DB     |
| `db2`       | PostgreSQL streaming replica            | DB     |

7 hosts instead of the suggested 4–6 because the brief requires **web and app
tiers on separate hosts** *and* 2x redundancy on each, plus DB
primary/replica. `lb1` is a single node — this is a stated, accepted SPOF
(see `docs/architecture.md`), traded off against free-tier IP/cost limits.
Everything below the LB is redundant and survives a single node failure.

## Two ways to run this

### 1. Local test on WSL Ubuntu (no real VMs, no cost)
We simulate the 7 hosts as `systemd`-enabled Docker containers reachable over
SSH, so Ansible manages them exactly as it would manage EC2 instances.
See `docker/README.md`.

### 2. Real build on AWS free tier
`scripts/aws_provision.sh` launches 7x `t2.micro`/`t3.micro` EC2 instances
(Ubuntu 22.04 LTS, 8GB gp3 root volume — free tier eligible), creates
security groups enforcing tier isolation, and prints an `inventory/hosts_aws.ini`
ready for Ansible. See that script's header comments for exact steps.

## Quickstart

```bash
# 1. Test locally in WSL first
cd docker && docker compose up -d --build
cd ..
ansible -i inventory/hosts.ini all -m ping

# 2. Configure Vault-encrypted secrets (DB password, etc.)
ansible-vault create group_vars/all/vault.yml
# put: vault_db_password: "changeme-strong-password"

# 3. Run the whole build
ansible-playbook -i inventory/hosts.ini site.yml --ask-vault-pass

# 4. Prove HA: kill a web/app node mid-demo, traffic keeps flowing
docker stop web1   # or: aws ec2 stop-instances --instance-ids <web1-id>
curl -k https://localhost/          # still works via web2/app2

# 5. Prove DR: restore from the latest backup
bash scripts/test_restore.sh
```

## Repo layout
```
inventory/          Ansible inventories (local docker + AWS)
group_vars/          Per-tier variables + Ansible Vault secrets
roles/                One role per concern (common, security, firewall,
                       haproxy, webserver, appserver, database, backup)
site.yml              Top-level playbook — the single automation entry point
bootstrap.sh           One-command "stand the whole thing up" wrapper
docker/                Local WSL test harness (docker-compose + SSH images)
scripts/               aws_provision.sh, test_restore.sh
docs/                  architecture.md, dr-runbook.md, security-scan-notes.md,
                       operator-runbook.md — the "Operations pack" deliverable
```

## Design decisions (short version — full version in docs/architecture.md)
- **Debian-family (Ubuntu 22.04)** everywhere for consistency across free-tier
  eligible AMIs; AppArmor (not SELinux) is the MAC control in scope.
- **Nginx** for web tier (lighter, simpler reverse-proxy config than Apache).
- **PostgreSQL streaming replication** (async) over MySQL — simpler HA story,
  built-in logical/physical replication tooling.
- **HAProxy** over Nginx-as-LB — purpose-built for L4/L7 load balancing with
  first-class health checks and a stats page.
- **Ansible Vault** for all secrets — nothing sensitive is committed in plaintext.
