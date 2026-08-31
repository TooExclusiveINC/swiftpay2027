#!/usr/bin/env bash
# One-command entry point. Run from the repo root.
#   ./bootstrap.sh local   -> stand up the docker-based WSL test environment
#   ./bootstrap.sh aws     -> assumes scripts/aws_provision.sh already ran
#                             and inventory/hosts_aws.ini exists
set -euo pipefail

MODE="${1:-local}"

if [ ! -f "group_vars/all/vault.yml" ]; then
  echo "ERROR: group_vars/all/vault.yml not found."
  echo "  cp group_vars/all/vault.yml.example group_vars/all/vault.yml"
  echo "  # edit in real passwords, then:"
  echo "  ansible-vault encrypt group_vars/all/vault.yml"
  exit 1
fi

if [ ! -f "$HOME/.ssh/swiftpay_ansible" ]; then
  echo "Generating dedicated ansible SSH keypair..."
  ssh-keygen -t ed25519 -f "$HOME/.ssh/swiftpay_ansible" -N "" -C "swiftpay-ansible"
fi

case "$MODE" in
  local)
    echo "== Bringing up local Docker test hosts =="
    (cd docker && docker compose up -d --build)
    echo "Waiting for SSH on all containers..."
    sleep 8
    ansible -i inventory/hosts.ini all -m ping
    echo "== Running site.yml against local containers =="
    ansible-playbook -i inventory/hosts.ini site.yml --ask-vault-pass
    ;;
  aws)
    if [ ! -f "inventory/hosts_aws.ini" ]; then
      echo "ERROR: inventory/hosts_aws.ini not found. Run scripts/aws_provision.sh first,"
      echo "       then copy inventory/hosts_aws.ini.example to inventory/hosts_aws.ini and fill in IPs."
      exit 1
    fi
    echo "== Running site.yml against AWS =="
    ansible-playbook -i inventory/hosts_aws.ini site.yml --ask-vault-pass
    ;;
  *)
    echo "Usage: $0 [local|aws]"
    exit 1
    ;;
esac

echo "Done. curl -k https://localhost/ (local) or https://<lb1-public-ip>/ (aws)"
