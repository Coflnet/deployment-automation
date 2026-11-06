#!/usr/bin/env bash
# Generate the new Redpanda `admin` SASL password into a private, git-ignored file.
# ansible/harden-admin-auth.yml (--tags password) reads it, rotates the user through
# the admin API and installs it as root's rpk login on every broker; Ansible sends
# it inside the module payload over SSH, never in argv or output.
#
# Usage: scripts/redpanda-admin/generate-admin-password.sh
# Output: secrets/redpanda-admin-password (0600, one line, 40 letters and digits)
# Never overwrites: to rotate again later, move the old file aside first.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FILE=${REDPANDA_ADMIN_PASSWORD_FILE:-$ROOT/secrets/redpanda-admin-password}
LENGTH=40

die() { echo "error: $*" >&2; exit 1; }

# Letters and digits only: no quoting issues in JSON, YAML, curl configs or SASLprep.
random_password() {
  local value
  value=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$LENGTH") || true
  [[ ${#value} -eq $LENGTH ]] || die "could not read enough random bytes"
  printf '%s' "$value"
}

check_written() {
  [[ $(stat -c %a "$FILE") == 600 ]] || die "$FILE is not mode 0600"
  grep -qxE "[A-Za-z0-9]{$LENGTH}" "$FILE" || die "$FILE has unexpected content"
}

prepare_dir() {
  local dir
  dir=$(dirname "$FILE")
  [[ -d $dir ]] && return 0
  mkdir -p "$dir"
  chmod 0700 "$dir"
}

main() {
  [[ $# -eq 0 ]] || die "usage: $0 (no arguments)"
  [[ ! -e $FILE ]] || die "$FILE already exists; refusing to overwrite"
  umask 077
  local password
  password=$(random_password)
  prepare_dir
  ( set -o noclobber; printf '%s\n' "$password" > "$FILE" ) || die "could not create $FILE"
  check_written
  echo "wrote a $LENGTH-character password to $FILE (not shown)"
}

main "$@"
