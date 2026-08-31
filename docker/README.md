# Local test harness (WSL Ubuntu)

Simulates the 7 SwiftPay hosts as systemd-enabled Docker containers reachable
over SSH, so Ansible manages them exactly as it will manage real EC2
instances later — same playbooks, same roles, zero changes.

## Prereqs (inside your WSL Ubuntu shell)

```bash
# Docker Engine inside WSL2 (skip if you already use Docker Desktop's WSL integration)
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker

# Ansible + collections
sudo apt update && sudo apt install -y ansible python3-pip
ansible-galaxy collection install community.general

# SSH keypair Ansible will use for every host (also reused for AWS later)
ssh-keygen -t ed25519 -f ~/.ssh/swiftpay_ansible -N "" -C "swiftpay-ansible"
```

## Bring the lab up

```bash
cd swiftpay-infra
cp group_vars/all/vault.yml.example group_vars/all/vault.yml
# edit group_vars/all/vault.yml with real values, then:
ansible-vault encrypt group_vars/all/vault.yml

cd docker
docker compose up -d --build      # ~2-3 min first time (7 containers)
docker compose ps                 # confirm all 7 are "Up"
```

## Test connectivity, then run the whole build

```bash
cd ..
ansible -i inventory/hosts.ini all -m ping
ansible-playbook -i inventory/hosts.ini site.yml --ask-vault-pass
```

## Demo the HA requirement

```bash
curl -k https://localhost/                 # through HAProxy on lb1 (port 2201 is SSH only;
                                             # lb1 also publishes 80/443 — add "80:80" "443:443"
                                             # to lb1's ports in docker-compose.yml if you want
                                             # to curl it from the WSL host directly)
docker stop swiftpay-lab-web1-1             # kill a web node mid-demo
curl -k https://localhost/                  # still works — HAProxy routes around it
docker start swiftpay-lab-web1-1            # bring it back
```

## Tear down

```bash
docker compose down -v
```

## Why Docker instead of nested VirtualBox VMs in WSL2?

Nested virtualization (VirtualBox/KVM inside WSL2) is unreliable without
Hyper-V passthrough tuning and burns far more RAM than a laptop typically
has free for 7 concurrent VMs. Docker containers with systemd give us real
independent hosts — real `systemctl`, real `ufw`, real `apt`, real SSH — at
a fraction of the resource cost, which is what actually matters for testing
Ansible roles before spending AWS free-tier hours on the real thing.
