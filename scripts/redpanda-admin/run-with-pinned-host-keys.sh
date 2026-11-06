#!/usr/bin/env bash
# Runs ansible-playbook against the Redpanda brokers with strict SSH host-key checking
# against ~/.ssh/known_hosts, like dev/ansible's 02-roll-redpanda-shared-root-trust.yml
# (ansible.cfg turns checking off and uses /dev/null as known_hosts).
#
# Usage: scripts/redpanda-admin/run-with-pinned-host-keys.sh <playbook> [ansible-playbook args...]
#   e.g. scripts/redpanda-admin/run-with-pinned-host-keys.sh ansible/harden-admin-auth.yml --tags preflight
# Overrides: REDPANDA_KNOWN_HOSTS, REDPANDA_INVENTORY, REDPANDA_SSH_KEY
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
KNOWN_HOSTS=${REDPANDA_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}
INVENTORY=${REDPANDA_INVENTORY:-$ROOT/artifacts/hosts.ini}
SSH_KEY=${REDPANDA_SSH_KEY:-$HOME/.ssh/id_rsa}

die() { echo "error: $*" >&2; exit 1; }

# First field of every host line in the [redpanda] group.
inventory_brokers() {
  awk '/^\[/ { group = $0; next } group == "[redpanda]" && NF && $1 !~ /^[#;]/ { print $1 }' "$INVENTORY"
}

# Prints found/missing per broker (never the keys); fails if any is missing.
require_known_hosts() {
  local brokers broker missing=0
  [[ -r $KNOWN_HOSTS ]] || die "known_hosts not found: $KNOWN_HOSTS"
  brokers=$(inventory_brokers)
  [[ -n $brokers ]] || die "no [redpanda] hosts in $INVENTORY"
  for broker in $brokers; do
    if ssh-keygen -F "$broker" -f "$KNOWN_HOSTS" >/dev/null; then
      echo "host key $broker: found"
    else
      echo "host key $broker: missing"
      missing=1
    fi
  done
  [[ $missing -eq 0 ]] || die "add the missing host keys to $KNOWN_HOSTS (checked out of band) first"
}

main() {
  [[ $# -ge 1 ]] || die "usage: $0 <playbook> [ansible-playbook args...]"
  [[ -r $INVENTORY ]] || die "inventory not found: $INVENTORY"
  require_known_hosts
  export ANSIBLE_HOST_KEY_CHECKING=True
  # Own control sockets: never reuse a master opened earlier without host-key checking.
  export ANSIBLE_SSH_CONTROL_PATH_DIR=$HOME/.ansible/cp-redpanda-pinned
  export ANSIBLE_SSH_ARGS="-o ControlMaster=auto -o ControlPersist=30m -o ConnectionAttempts=3 -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KNOWN_HOSTS -o UpdateHostKeys=no"
  exec ansible-playbook --private-key "$SSH_KEY" -i "$INVENTORY" "$@"
}

main "$@"
