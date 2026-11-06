#!/usr/bin/env bash
# Create a SCRAM-SHA-256 user on the Redpanda cluster through the admin API.
# The call uses the broker's own node certificate (mTLS). Once the admin API is
# hardened (admin_api_require_auth=true) it also needs the admin login: it is
# read from REDPANDA_ADMIN_PASSWORD_FILE, or from secrets/redpanda-admin-password
# when that file exists. Before hardening no file is needed.
# The new password is generated locally, kept in a 0600 file and sent, together
# with the admin login, as a curl config over SSH stdin: no secret appears in argv
# or output. Only the controller leader accepts the call; other brokers answer
# 307, which curl follows (-L keeps the POST; --location-trusted keeps the login
# on the redirect to another host).
#
# Usage: scripts/kafka-client/create-scram-user.sh <name> [broker-ip]
# Password file (git-ignored): clients/<name>/scram-password
# Refuses to touch a user that already exists (no password reset).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DEFAULT_BROKER=195.201.61.227
CERTS=/etc/redpanda/certs

die() { echo "error: $*" >&2; exit 1; }

check_args() {
  [[ $# -ge 1 && $# -le 2 ]] || die "usage: $0 <name> [broker-ip]"
  [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die "invalid name: $1"
  [[ ${2:-$DEFAULT_BROKER} =~ ^[0-9.]+$ ]] || die "invalid broker ip: ${2:-}"
}

broker() { ssh -o BatchMode=yes -o ConnectTimeout=10 "root@$BROKER" "$@"; }

# Dies when the listing itself fails, so "absent" is never a guess.
user_exists() {
  local users
  users=$(broker rpk security user list) || die "could not list users on $BROKER"
  tail -n +2 <<<"$users" | grep -qx -- "$1"
}

ensure_password() {
  local file=$1
  [[ -s $file ]] && return 0
  ( umask 077; mkdir -p "$(dirname "$file")"; openssl rand -hex 24 > "$file" )
}

# Picks the admin password file: explicit setting (must exist), else the
# hardening file if present, else none (admin API not hardened yet).
admin_password_file() {
  local explicit=${REDPANDA_ADMIN_PASSWORD_FILE:-}
  if [[ -n $explicit ]]; then
    [[ -r $explicit ]] || die "REDPANDA_ADMIN_PASSWORD_FILE not readable: $explicit"
    echo "$explicit"
    return
  fi
  [[ -r $ROOT/secrets/redpanda-admin-password ]] && echo "$ROOT/secrets/redpanda-admin-password"
  return 0
}

# Writes a curl config (stdin of the remote curl): the JSON body and, if given,
# the admin login. Values are quoted for curl's config syntax.
curl_config() {
  python3 -I -c 'import json, sys

def first_line(path):
    value = open(path).read().split("\n")[0].strip("\r")
    if not value or any(ord(c) < 32 for c in value):
        sys.exit("empty or invalid password in " + path)
    return value

def quoted(value):
    return "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

name, user_file, admin_file = sys.argv[1:4]
body = json.dumps({"username": name, "password": first_line(user_file),
                   "algorithm": "SCRAM-SHA-256"})
lines = ["data-binary = " + quoted(body)]
if admin_file:
    lines.append("user = " + quoted("admin:" + first_line(admin_file)))
print("\n".join(lines))' "$1" "$2" "$3"
}

# Prints the final HTTP status; the error body (no secrets) goes to stderr.
create_user() {
  local name=$1 file=$2 admin_file=$3
  curl_config "$name" "$file" "$admin_file" | broker "curl -sS -L --location-trusted -K - \
    -o /dev/stderr -w '%{http_code}\n' \
    --cert $CERTS/node.crt --key $CERTS/node.key --cacert $CERTS/truststore.pem \
    -H 'Content-Type: application/json' \
    https://$BROKER:9644/v1/security/users"
}

main() {
  check_args "$@"
  local name=$1 file=$ROOT/clients/$1/scram-password status admin_file
  BROKER=${2:-$DEFAULT_BROKER}
  admin_file=$(admin_password_file)
  user_exists "$name" && die "user $name already exists; not changing it"
  ensure_password "$file"
  status=$(create_user "$name" "$file" "$admin_file") || die "admin API call failed"
  [[ $status == 403 && -z $admin_file ]] &&
    die "admin API returned 403: it needs the admin login, set REDPANDA_ADMIN_PASSWORD_FILE"
  [[ $status == 200 ]] || die "admin API returned HTTP $status"
  user_exists "$name" || die "user $name not listed after create"
  echo "created SCRAM-SHA-256 user $name; password in $file"
}

main "$@"
