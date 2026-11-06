#!/usr/bin/env bash
# Owner-run: pre-create a client's topic and confine its SCRAM user to one prefix.
# Needs the Redpanda admin (superuser) SASL password. It is read from the file in
# REDPANDA_ADMIN_PASSWORD_FILE, else from secrets/redpanda-admin-password when that
# exists (after the admin API hardening), else with a silent prompt, and sent over SSH
# stdin into rpk's environment; it never appears in argv, history or output.
#
# Usage: scripts/kafka-client/grant-prefix-access.sh <user> <prefix> [topic] [partitions]
#   e.g. scripts/kafka-client/grant-prefix-access.sh cait-mimir cait-mimir- cait-mimir-ingest 3
#
# Grants (prefixed, nothing cluster-wide):
#   topic <prefix>: read, write, describe (no create: new topics would bypass the budget,
#                   so the client must run with topic auto-creation off)
#   group <prefix>: read, describe
# The topic (if given) gets RF 3, max.message.bytes 16000000 (Mimir batches up to
# 16 MB, the cluster default is 1 MiB), retention 24 h and a disk budget:
# BUDGET_BYTES (default 50000000000 = 50 GB) per broker for the whole topic, split
# evenly over the partitions. Size-based cleanup removes whole segments only, so a
# partition holds up to retention.bytes plus one segment: each partition's
# retention.bytes is its share minus one 128 MiB segment.
# With RF 3 on 3 brokers every broker holds every partition, so the cluster total
# is 3 x BUDGET_BYTES.
# Existing topics and ACLs are left as they are; adding an ACL twice is harmless.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BROKER=195.201.61.227
SEGMENT_BYTES=134217728

die() { echo "error: $*" >&2; exit 1; }

check_args() {
  [[ $# -ge 2 && $# -le 4 ]] || die "usage: $0 <user> <prefix> [topic] [partitions]"
  [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die "invalid user: $1"
  [[ $2 =~ ^[a-z0-9][a-z0-9-]*-$ ]] || die "prefix must end with '-': $2"
  [[ -z ${3:-} || ( $3 == "$2"* && $3 =~ ^[a-z0-9-]+$ ) ]] || die "topic must start with the prefix: ${3:-}"
  [[ ${4:-3} =~ ^[1-9][0-9]{0,2}$ ]] || die "invalid partitions: ${4:-}"
  [[ ${BUDGET_BYTES:-50000000000} =~ ^[1-9][0-9]{9,12}$ ]] || die "invalid BUDGET_BYTES"
}

retention_bytes_per_partition() {
  local share=$(( ${BUDGET_BYTES:-50000000000} / $1 - SEGMENT_BYTES ))
  (( share >= 1000000000 )) || die "budget too small for $1 partitions"
  echo "$share"
}

read_admin_password() {
  local file=${REDPANDA_ADMIN_PASSWORD_FILE:-}
  [[ -z $file && -r $ROOT/secrets/redpanda-admin-password ]] && file=$ROOT/secrets/redpanda-admin-password
  if [[ -n $file ]]; then
    printf '%s\n' "$(head -n 1 -- "$file" | tr -d '\r')"
    return
  fi
  local pass
  IFS= read -rsp "Redpanda admin SASL password: " pass </dev/tty
  echo >&2
  printf '%s\n' "$pass"
}

# Runs on the broker. First stdin line = admin password, never echoed.
REMOTE_SCRIPT='
set -euo pipefail
IFS= read -r RPK_PASS
export RPK_PASS RPK_USER=admin RPK_SASL_MECHANISM=SCRAM-SHA-256
user=$1 prefix=$2 topic=$3 parts=$4 keep=$5 seg=$6
if [ -n "$topic" ]; then
  if rpk topic describe "$topic" >/dev/null 2>&1; then
    echo "topic $topic exists, left unchanged"
  else
    rpk topic create "$topic" -p "$parts" -r 3 \
      -c max.message.bytes=16000000 -c retention.ms=86400000 \
      -c retention.bytes="$keep" -c segment.bytes="$seg"
  fi
  rpk topic describe "$topic" -c | grep -E "^(retention|segment.bytes|max.message|cleanup)"
fi
rpk security acl create --allow-principal "User:$user" \
  --operation read,write,describe \
  --topic "$prefix" --resource-pattern-type prefixed
rpk security acl create --allow-principal "User:$user" \
  --operation read,describe \
  --group "$prefix" --resource-pattern-type prefixed
echo "--- ACLs for User:$user"
rpk security acl list --allow-principal "User:$user"
'

main() {
  check_args "$@"
  local user=$1 prefix=$2 topic=${3:-} parts=${4:-3} keep
  keep=$(retention_bytes_per_partition "$parts")
  echo "topic ${topic:-<none>}: $parts partitions, retention.bytes $keep each"
  # printf %q may emit $'...' quoting: root's login shell on the brokers is bash.
  read_admin_password | ssh -o BatchMode=yes -o ConnectTimeout=10 "root@$BROKER" \
    "bash -c $(printf %q "$REMOTE_SCRIPT") grant $user $prefix ${topic:-''} $parts $keep $SEGMENT_BYTES"
}

main "$@"
