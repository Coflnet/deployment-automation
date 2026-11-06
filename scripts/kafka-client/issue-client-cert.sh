#!/usr/bin/env bash
# Issue a long-lived Kafka client certificate from the ca_kafka CA (the CA the
# brokers' Kafka listener trusts and that signs their Kafka server certificate).
#
# Usage: scripts/kafka-client/issue-client-cert.sh <name> [days]
#   name  lowercase DNS label, becomes CN=<name>, O=Coflnet (e.g. cait-mimir)
#   days  validity, default 730
#
# Output (git-ignored): clients/<name>/<YYYYMMDD>/
#   client.key   EC P-256, unencrypted PKCS#8 (0600), hand over to the client only
#   client.crt   leaf, clientAuth only
#   ca.crt       server trust: ca_kafka (signs the brokers' Kafka certificates today)
#                plus the shared Coflnet Internal Root (the brokers' future server root)
#   receipt.txt  public facts: serial, validity, fingerprints, not_after epoch
# A run never overwrites an existing directory. Renew by running again on another day.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CA_DIR=$ROOT/ansible/tls/ca_kafka
SHARED_ROOT=$ROOT/ansible/tls/coflnet-internal-root-ca.crt
SHARED_ROOT_SHA256=EB:BB:4E:D3:67:04:F0:0D:27:8E:38:F9:D7:B1:0D:AA:B9:80:6C:85:C2:AB:B0:07:52:3A:EB:AC:99:4E:24:F1

die() { echo "error: $*" >&2; exit 1; }

check_args() {
  [[ $# -ge 1 && $# -le 2 ]] || die "usage: $0 <name> [days]"
  [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die "invalid name: $1"
  [[ ${2:-730} =~ ^[1-9][0-9]{0,4}$ ]] || die "invalid days: ${2:-}"
  [[ -r $CA_DIR/ca.crt && -r $CA_DIR/ca.key ]] || die "ca_kafka CA not found in $CA_DIR"
  [[ -r $SHARED_ROOT ]] || die "shared root not found: $SHARED_ROOT"
}

check_ca_outlives() {
  local days=$1
  openssl x509 -in "$CA_DIR/ca.crt" -noout -checkend $((days * 86400 + 86400)) >/dev/null ||
    die "ca_kafka expires before a ${days}-day leaf would"
}

write_ext() {
  cat > "$1" <<'EOF'
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
EOF
}

issue() {
  local name=$1 days=$2 dir=$3
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$dir/client.key" 2>/dev/null
  openssl req -new -key "$dir/client.key" -subj "/O=Coflnet/CN=$name" -out "$dir/client.csr"
  write_ext "$dir/client.ext"
  openssl x509 -req -in "$dir/client.csr" -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" \
    -set_serial "0x$(openssl rand -hex 16)" -days "$days" -sha256 \
    -extfile "$dir/client.ext" -out "$dir/client.crt" 2>/dev/null
  rm -f "$dir/client.ext"
  write_trust_bundle "$dir/ca.crt"
}

write_trust_bundle() {
  local fp
  fp=$(openssl x509 -in "$SHARED_ROOT" -noout -fingerprint -sha256 | cut -d= -f2)
  [[ $fp == "$SHARED_ROOT_SHA256" ]] || die "unexpected shared root fingerprint: $fp"
  cat "$CA_DIR/ca.crt" "$SHARED_ROOT" > "$1"
}

verify() {
  local dir=$1
  openssl verify -x509_strict -purpose sslclient -CAfile "$CA_DIR/ca.crt" "$dir/client.crt" >/dev/null ||
    die "issued certificate does not verify"
  [[ $(openssl pkey -in "$dir/client.key" -pubout) == $(openssl x509 -in "$dir/client.crt" -noout -pubkey) ]] ||
    die "key and certificate do not match"
}

write_receipt() {
  local dir=$1 not_after
  not_after=$(openssl x509 -in "$dir/client.crt" -noout -enddate | cut -d= -f2)
  {
    openssl x509 -in "$dir/client.crt" -noout -subject -issuer -serial -startdate -enddate
    echo "not_after_epoch=$(date -u -d "$not_after" +%s)"
    echo "leaf_$(openssl x509 -in "$dir/client.crt" -noout -fingerprint -sha256)"
    echo "issuer_$(openssl x509 -in "$CA_DIR/ca.crt" -noout -fingerprint -sha256)"
    echo "trust_bundle=ca_kafka + Coflnet Internal Root $SHARED_ROOT_SHA256"
  } > "$dir/receipt.txt"
}

main() {
  check_args "$@"
  local name=$1 days=${2:-730}
  local dir=$ROOT/clients/$name/$(date -u +%Y%m%d)
  check_ca_outlives "$days"
  [[ ! -e $dir ]] || die "$dir already exists; refusing to overwrite"
  umask 077
  mkdir -p "$dir"
  issue "$name" "$days" "$dir"
  verify "$dir"
  write_receipt "$dir"
  chmod 0644 "$dir/client.crt" "$dir/client.csr" "$dir/ca.crt" "$dir/receipt.txt"
  cat "$dir/receipt.txt"
  echo "written to $dir"
}

main "$@"
