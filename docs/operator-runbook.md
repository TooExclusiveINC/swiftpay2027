# Operator Runbook — Day-to-Day

## Checking overall health

```bash
# LB stats page (shows both web nodes' up/down state)
curl -k https://<lb1-ip>:8404/stats

# Direct health checks
curl -k https://<lb1-ip>/healthz          # through the whole stack
curl http://<web-internal-ip>/healthz     # web tier direct
curl http://<app-internal-ip>:8000/healthz # app tier direct

# node_exporter (basic resource metrics) on any host
curl http://<host-internal-ip>:9100/metrics | head -30
```

## Common tasks

### Deploying an app code change
```bash
# Edit roles/appserver/files/app.py, then:
ansible-playbook -i inventory/hosts.ini site.yml --limit app --ask-vault-pass
```

### Rotating a secret (e.g. DB password)
```bash
ansible-vault edit group_vars/all/vault.yml
ansible-playbook -i inventory/hosts.ini site.yml --limit db,app --ask-vault-pass
```

### Adding a third web/app node
1. Add it to `docker-compose.yml` (or launch a new EC2 instance) and to
   `inventory/hosts.ini` under `[web]` or `[app]`, with a unique `internal_ip`.
2. Re-run `site.yml` — HAProxy and Nginx upstream blocks are templated from
   `groups['web']` / `groups['app']`, so the new node is picked up automatically.

### Checking recent backups
```bash
ssh -p 2231 ansible@127.0.0.1 "ls -lh /var/backups/swiftpay/"
ssh -p 2201 ansible@127.0.0.1 "ls -lh /var/backups/swiftpay-offsite/"
```

### Checking fail2ban bans
```bash
ansible all -i inventory/hosts.ini -b -m shell -a "fail2ban-client status sshd"
```

### Viewing firewall rules on a host
```bash
ansible web -i inventory/hosts.ini -b -m shell -a "ufw status numbered"
```

## Escalation

If HAProxy's stats page shows both web nodes DOWN, or `/healthz` fails from
outside the LB: check `docs/dr-runbook.md` Scenario A/B depending on whether
the failure is app/web tier (fast — just restart the service/host) or DB
tier (follow the DR runbook's promotion or restore steps).
