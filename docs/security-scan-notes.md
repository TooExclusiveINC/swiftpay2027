# Security Hardening — Scan Report & Remediation Notes

## Running the scan

Lynis is the fastest automated scan to run against every host with zero
extra infrastructure (no server component needed, unlike OpenSCAP's SCAP
Security Guide setup).

```bash
# On each host (or via Ansible ad-hoc against all):
ansible all -i inventory/hosts.ini -b -m shell -a \
  "which lynis || (apt update && apt install -y lynis)"

ansible all -i inventory/hosts.ini -b -m shell -a \
  "lynis audit system --quiet" > docs/evidence/lynis-$(date +%F).log
```

Run it, then paste the real hardening-index score and top findings below —
this file is a **template**; replace the example content with your actual
scan output before submission.

## Example scan summary (replace with your real numbers)

```
Hardening index : 68 [######______]
Tests performed : 224
Plugins enabled : 1
```

## Findings and remediation status

| Finding | Severity | Remediated? | Notes |
|---|---|---|---|
| No password aging policy (`PASS_MAX_DAYS`) configured | Suggestion | ✅ Yes | Added to `common` role: `PASS_MAX_DAYS 90` in `/etc/login.defs` |
| `PermitRootLogin` not explicitly disabled | Warning | ✅ Yes | `roles/security/templates/sshd_config.j2` sets `PermitRootLogin no` |
| No firewall active by default on fresh Ubuntu image | Warning | ✅ Yes | `roles/firewall` enables ufw with default-deny |
| `AllowTcpForwarding` not restricted | Suggestion | ⚠️ Not fixed | App tier doesn't need SSH tunneling; low actual risk given key-only auth + fail2ban + internal-only SSH exposure. Accepted. |
| Postgres `log_min_duration_statement` may log sensitive query params | Suggestion | ⚠️ Not fixed | Useful for debugging slow queries during the demo period; flagged for review before real production data is loaded — would set to a higher threshold or disable in prod. |
| No intrusion detection (AIDE / Tripwire) installed | Suggestion | ⚠️ Not fixed (documented gap) | `auditd` is running (syscall auditing) but file-integrity monitoring wasn't added — time-boxed out of the 1-day build; noted as a "next" item in `docs/architecture.md`. |
| Legacy/unused SUID binaries present on base Ubuntu image | Suggestion | ⚠️ Not fixed | Standard image behavior; would require a hardened base image (CIS-benchmarked AMI) to address properly — out of scope for a hand-rolled free-tier build. |

## Why some findings are "accepted, not fixed"

Section D of the brief asks for defence in depth, not a perfect score — and
explicitly asks us to "note the ones you chose not to fix and why," which is
what the table above does. The controls that matter most for a fintech
(key-only SSH, no root login, tier-isolated firewall, mandatory AppArmor,
least-privilege service accounts, automated patching) are all implemented
and enabled by default — not toggled off to inflate a demo score.

## Known lab-only limitation: auditd in Docker

auditd fails to start inside the Docker-based local test containers
because it requires direct netlink access to the kernel's audit subsystem,
which Docker containers (even privileged ones) don't fully expose. This is
a Docker limitation, not a configuration error — auditd starts and runs
normally on real VMs/EC2 instances. The common role treats this failure
as non-fatal (failed_when: false) so the lab can proceed; on the real AWS
build, verify systemctl status auditd shows active/running.
