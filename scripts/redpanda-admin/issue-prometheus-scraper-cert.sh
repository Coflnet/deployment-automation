#!/usr/bin/env bash
# Re-issue the Prometheus scrape client certificate for the Redpanda admin API (9644)
# from the legacy admin CA (ansible/tls/ca), with a NEW EC P-256 key.
#
# Usage: scripts/redpanda-admin/issue-prometheus-scraper-cert.sh [days]
#   days  validity, default 730
#
# Output (git-ignored): clients/prometheus-redpanda-scraper/<YYYYMMDD>/
#   tls.key      EC P-256, unencrypted PKCS#8 (0600); goes only into the Kubernetes Secret
#   tls.crt      leaf CN=prometheus-redpanda-scraper, O=Coflnet, clientAuth only
#   ca.crt       server trust: the legacy admin CA (signs every broker's node.crt)
#   receipt.txt  public facts: serial, validity, fingerprints, not_after epoch
# Prints the kubectl command for the owner; it runs nothing against a cluster.
# Builds in a temporary directory and moves it into place only when complete.
# The old certificate cannot be revoked (no CRL on the brokers); with
# admin_api_require_auth=true it is limited to readiness and metrics, like this one.
# A run never overwrites an existing directory.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CA_DIR=${REDPANDA_ADMIN_CA_DIR:-$ROOT/ansible/tls/ca}
CA_SHA256=${REDPANDA_ADMIN_CA_SHA256:-70:10:2E:5C:A9:FB:12:A6:00:8C:67:3E:9F:F2:AE:21:1E:3C:99:5E:CD:90:00:3C:3B:52:67:2C:A3:AC:1B:72}
NAME=prometheus-redpanda-scraper
KUBE_CONTEXT=${KUBE_CONTEXT:-talos-eu}
SECRET=redpanda-admin-metrics-client

die() { echo "error: $*" >&2; exit 1; }

check_args() {
  [[ $# -le 1 ]] || die "usage: $0 [days]"
  [[ ${1:-730} =~ ^[1-9][0-9]{0,3}$ ]] || die "invalid days: ${1:-}"
  [[ -r $CA_DIR/ca.crt && -r $CA_DIR/ca.key ]] || die "legacy admin CA not found in $CA_DIR"
}

# Dies unless the certificate and key hold the same, non-empty public key.
require_key_match() {
  local cert_pub key_pub
  cert_pub=$(openssl x509 -in "$1" -noout -pubkey) || die "cannot read $1"
  key_pub=$(openssl pkey -in "$2" -pubout) || die "cannot read $2"
  [[ -n $cert_pub && $cert_pub == "$key_pub" ]] || die "$2 does not match $1"
}

check_ca() {
  local days=$1 fp
  fp=$(openssl x509 -in "$CA_DIR/ca.crt" -noout -fingerprint -sha256 | cut -d= -f2)
  [[ $fp == "$CA_SHA256" ]] || die "unexpected admin CA fingerprint: $fp"
  require_key_match "$CA_DIR/ca.crt" "$CA_DIR/ca.key"
  openssl x509 -in "$CA_DIR/ca.crt" -noout -checkend $((days * 86400 + 86400)) >/dev/null ||
    die "admin CA expires before a ${days}-day leaf would"
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
  local days=$1 dir=$2
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$dir/tls.key"
  openssl req -new -key "$dir/tls.key" -subj "/O=Coflnet/CN=$NAME" -out "$dir/tls.csr"
  write_ext "$dir/tls.ext"
  openssl x509 -req -in "$dir/tls.csr" -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" \
    -set_serial "0x$(openssl rand -hex 16)" -days "$days" -sha256 \
    -extfile "$dir/tls.ext" -out "$dir/tls.crt"
  rm -f "$dir/tls.ext" "$dir/tls.csr"
  cp "$CA_DIR/ca.crt" "$dir/ca.crt"
}

verify() {
  local dir=$1
  openssl verify -x509_strict -purpose sslclient -CAfile "$CA_DIR/ca.crt" "$dir/tls.crt" >/dev/null ||
    die "issued certificate does not verify"
  require_key_match "$dir/tls.crt" "$dir/tls.key"
}

write_receipt() {
  local dir=$1 not_after
  not_after=$(openssl x509 -in "$dir/tls.crt" -noout -enddate | cut -d= -f2)
  {
    openssl x509 -in "$dir/tls.crt" -noout -subject -issuer -serial -startdate -enddate
    echo "not_after_epoch=$(date -u -d "$not_after" +%s)"
    echo "leaf_$(openssl x509 -in "$dir/tls.crt" -noout -fingerprint -sha256)"
    echo "issuer_$(openssl x509 -in "$CA_DIR/ca.crt" -noout -fingerprint -sha256)"
  } > "$dir/receipt.txt"
}

print_owner_step() {
  local dir=$1
  cat <<EOF

Owner step (replaces the whole Secret, which also drops a last-applied annotation that may
hold the old key, and any labels; Prometheus reloads the files on its next scrape).
First confirm the live Secret is type Opaque (replace cannot change the type):
  kubectl --context $KUBE_CONTEXT -n prometheus get secret $SECRET -o jsonpath='{.type}{"\n"}'
  kubectl --context $KUBE_CONTEXT -n prometheus create secret generic $SECRET \\
    --from-file=tls.crt=$dir/tls.crt --from-file=tls.key=$dir/tls.key --from-file=ca.crt=$dir/ca.crt \\
    --dry-run=client -o yaml | kubectl --context $KUBE_CONTEXT -n prometheus replace -f -
Then check in Prometheus that the three Redpanda targets (port redpanda-metrics, /public_metrics) are UP.
EOF
}

main() {
  check_args "$@"
  local days=${1:-730}
  local dir=$ROOT/clients/$NAME/$(date -u +%Y%m%d) work
  check_ca "$days"
  [[ ! -e $dir ]] || die "$dir already exists; refusing to overwrite"
  umask 077
  mkdir -p "$(dirname "$dir")"
  work=$(mktemp -d "$(dirname "$dir")/.issue.XXXXXX")
  trap 'rm -rf -- "$work"' EXIT
  issue "$days" "$work"
  verify "$work"
  write_receipt "$work"
  chmod 0644 "$work/tls.crt" "$work/ca.crt" "$work/receipt.txt"
  chmod 0700 "$work"
  mv -T "$work" "$dir"
  trap - EXIT
  cat "$dir/receipt.txt"
  echo "written to $dir"
  print_owner_step "$dir"
}

main "$@"
