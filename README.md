# Terraform and Ansible Deployment for Redpanda

[![Build status](https://badge.buildkite.com/b4528cf1604a18231c935663db15739e56d202dde6d7a2ec2a.svg)](https://buildkite.com/redpanda/deployment-automation)

Terraform and Ansible configuration to easily provision a [Redpanda](https://www.redpanda.com/) cluster on AWS, GCP,
Azure, or IBM.

## Installation Prerequisites

Here are some prerequisites you'll need to install to run the content in this repo. You can also choose to use our
Dockerfile_FEDORA or Dockerfile_UBUNTU dockerfiles to build a local client if you'd rather not install terraform and
ansible on your machine.

* Install Terraform: https://www.terraform.io/downloads.html
* Install Ansible: https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html
* Depending on your system, you might need to install some python packages (e.g. `selinux` or `jmespath`). Ansible will
  throw an error with the expected python packages, both on local and remote machines.

### On Mac OS X:

You can use brew to install the prerequisites. You will also need to install gnu-tar:

```commandline
brew tap hashicorp/tap
brew install hashicorp/tap/terraform
brew install ansible
brew install gnu-tar
```

## Basic Usage:

```shell
# Set required ansible variables
export CLOUD_PROVIDER=aws
export ANSIBLE_COLLECTIONS_PATHS=${PWD}/artifacts/collections
export ANSIBLE_ROLES_PATH=${PWD}/artifacts/roles
export ANSIBLE_INVENTORY=${PWD}/${CLOUD_PROVIDER}/hosts.ini

# Assumes default private and public key names, if these aren't correct for you set them to the correct values

# Deploy VM
# ASSUMES YOU HAVE A DEFAULT VPC, if you don't, create one and set vpc_id and subnet_id
cd $CLOUD_PROVIDER
terraform init
terraform apply --auto-approve -var='public_key_path=~/.ssh/id_rsa.pub' -var='deployment_prefix=go-rp'
cd ..

# Install collections and roles
ansible-galaxy install -r ./requirements.yml

# Run a Playbook
# You need to pick the correct playbook for you, in this case we picked provision-cluster
ansible-playbook ansible/provision-cluster.yml --private-key ~/.ssh/id_rsa

# If you want Redpanda Console and our implementation of Prometheus and Grafana you will need to run the following
ansible-playbook ansible/deploy-monitor.yml --private-key ~/.ssh/id_rsa
ansible-playbook ansible/deploy-client.yml --private-key ~/.ssh/id_rsa
```

The playbooks can all be run in any order. However they are designed with the assumption that you will run only either the TLS or non TLS playbooks, not both. Currently we do not support converting a cluster from non-TLS to TLS or vice versa.

## Additional Documentation

More information on consuming this collection
is [available here](https://docs.redpanda.com/docs/deploy/deployment-option/self-hosted/manual/production/production-deployment-automation/)
in our official documentation.

## Troubleshooting

### On Mac OS X, Python unable to fork workers

If you see something like this:

```
ok: [34.209.26.177] => {“changed”: false, “stat”: {“exists”: false}}
objc[57889]: +[__NSCFConstantString initialize] may have been in progress in another thread when fork() was called.
objc[57889]: +[__NSCFConstantString initialize] may have been in progress in another thread when fork() was called. We cannot safely call it or ignore it in the fork() child process. Crashing instead. Set a breakpoint on objc_initializeAfterForkError to debug.
ERROR! A worker was found in a dead state
```

You might try resolving by setting an environment variable:
`export OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES`

See: https://stackoverflow.com/questions/50168647/multiprocessing-causes-python-to-crash-and-gives-an-error-may-have-been-in-progr

## Contribution Guide

### testing with a specific branch of redpanda-ansible-collection

Change the redpanda.cluster entry in your requirements.yml file to the following:

```yaml
  - name: https://github.com/redpanda-data/redpanda-ansible-collection.git
    type: git
    version: <<<YOUR BRANCH NAME>>>
```

### pre-commit

We use pre-commit to ensure good code health on this repo. To install
pre-commit [check the docs here](https://pre-commit.com/#install). The basic idea is that you'll have a fairly
comprehensive checkup happen on each commit, guaranteeing that everything will be properly formatted and validated. You
may also need to install some pre-requisite tools for pre-commit to work correctly. At the time of writing this
includes:

* [ansible-lint](https://ansible-lint.readthedocs.io/installing/#installing-from-source-code)
* [tflint](https://github.com/terraform-linters/tflint#installation)

## Ansible Linter Skip List Whys and Wherefores

A lot of effort to bring the linter and IDE into alignment without meaningful improvement in readability, outcomes or
correctness.

- jinja[spacing]
- yaml[brackets]
- yaml[line-length]

Breaks the play because intermediate commands in the pipe return nonzero (but irrelevant) error codes

- risky-shell-pipe 


## Create self signed certificate for consumer
  
  ```shell
  openssl req -new -newkey rsa:2048 -nodes -keyout skyblock.key -out skyblock.csr -subj "/CN=sky.coflnet.com/O=Coflnet"
  
  openssl ca -config ansible/tls/ca/ca.conf -keyfile ansible/tls/ca_kafka/ca.key -cert ansible/tls/ca_kafka/ca.crt -policy signing_policy -extensions signing_node_req -in skyblock.csr -out skyblock.crt -outdir . -batch
  ```

## Basic SASL setup
For detailed instructions see [redpanda university](https://university.redpanda.com/courses/take/hands-on-redpanda-cluster-operations/texts/39071127-lesson-iv-access-management)
```shell
admin_password=$(head -c 16  /dev/random | md5sum | cut -f 1 -d\ )
rpk cluster config set enable_sasl true
# create admin
rpk acl user create admin --password $admin_password
rpk cluster config set superusers '[admin]'
echo "admin_password: $admin_password"
```
### Create and authorize user for namespace
```shell
# don't forget to set the admin_password="pwd"
user_name=skyblock
prefix=sky # prefix of the topics will be extended with a dash (-) to create namespaces
user_password=$(head -c 16  /dev/random | md5sum | cut -f 1 -d\ )
rpk acl user create $user_name --password $user_password
# uses kafka api
rpk acl create --allow-host '*' --operation all --user admin --password $admin_password --sasl-mechanism SCRAM-SHA-256 --topic "$prefix-" --group "$prefix-" --resource-pattern-type prefixed --allow-principal User:$user_name
echo "user_password: $user_password"
```


## Coflnet Setup
We applied some patches to the playbook so to replicate the setup clone https://github.com/Coflnet/redpanda-ansible-cluster.git into `~/.ansible/collections/ansible_collections/redpanda/cluster`

## Admin API hardening

`truststore.pem` (admin API 9644, schema registry 8081, REST proxy 8082, internode RPC)
also trusts the shared `Coflnet Internal Root CA`, whose online intermediates issue many
clientAuth leaves. `ansible/harden-admin-auth.yml --tags truststore` makes it the legacy
admin CA alone (byte-identical to `ansible/tls/ca/ca.crt`, sha256 pinned).
`truststore_kafka.pem` (9092) is untouched and keeps the shared root. Lab evidence:
[docs/ADMIN-API-HARDENING-LAB.md](docs/ADMIN-API-HARDENING-LAB.md).

### Minimal path: remove the shared root

Needs only root SSH and the node certificates: no admin password, no rpk profile, and it
works with `admin_api_require_auth=false`. Run from the main checkout (it holds
`ansible/tls/ca`). `scripts/redpanda-admin/run-with-pinned-host-keys.sh` wraps
`ansible-playbook` with strict host-key checking against `~/.ssh/known_hosts` (it prints
found/missing per broker and refuses if one is missing), its own SSH control sockets and
`-i artifacts/hosts.ini --private-key ~/.ssh/id_rsa`.

```shell
R=scripts/redpanda-admin/run-with-pinned-host-keys.sh
P=ansible/harden-admin-auth.yml
$R $P --tags preflight                        # read-only
$R $P --check --tags truststore,verify_trust  # dry run, changes nothing
$R $P --tags truststore                       # one broker at a time
$R $P --tags verify_trust
```

- **preflight** reports per broker `truststore.pem=overlap (legacy admin CA + shared root)`,
  current peers on 9644/8081/8082, source IPs of recent Kafka connections as `admin`, and
  non-zero schema registry / proxy operations. It warns (does not stop) when a listener's
  loaded trust differs from the file; `--tags truststore` converges that.
- **truststore**, per broker: healthy cluster, backup to
  `/var/backups/redpanda-admin-hardening/truststore.pem.<overlap-sha256>`, re-check of the
  source sha256, install (regular file, mode 0644), then the loaded CRC32C of the admin, rpc,
  schema_registry and rest_proxy listeners on every shard. Expect `reloaded live`. When a
  listener keeps the old trust for 30 s (seen in the lab on a later replacement, and likely on
  brokers not restarted since the 2026-10-29 overlap roll), the broker gets a guarded restart:
  confirmation, no pre-restart risks, drain into maintenance, restart, ready and alive, end
  maintenance, full replication (a failure ends maintenance automatically). Then 30 s
  observation and a verify. Expect `loaded by a guarded broker restart` in that case.
- **Restart confirmation**: on a terminal, type `restart` at the prompt. Without a terminal,
  pass `-e harden_confirm_restart=<inventory_hostname>`; it confirms exactly that broker. Any
  other broker that needs a restart stops the run before its drain (its new file stays in
  place): rerun with that broker's name, the step continues where it stopped.
  `-e harden_truststore_restart=always` also restarts brokers whose file this run changed;
  it only acts in the run that writes the file, so a rerun after a stop does not restart
  again. Use the default (auto) when running without a terminal.
- **verify_trust**: legacy-only `truststore.pem` loaded by every listener and shard, node
  certificate verifies, `truststore_kafka.pem` unchanged, healthy cluster.

After the change, shared-root clients are refused on 9644, 8081 and 8082 (TLS `unknown ca`);
legacy-admin-CA clients and internode RPC keep working, and 9092 still accepts shared-root
leaves + SCRAM. Guards: real runs need explicit `--tags`; forward steps refuse `--limit`
(rollbacks allow it) and `--skip-tags preflight`.

**Rollback**: `$R $P --tags rollback_truststore` restores the backup (sha256 pinned), with the
same reload check and confirmed restart. **Killed run left a broker in maintenance**: as
root on a broker, `rpk cluster maintenance status`, then `rpk cluster maintenance disable <node_id>`.
**Listener stuck by hand**: the same sequence on that broker, `rpk cluster maintenance enable
<id> --wait`, `systemctl restart redpanda`, wait for `/v1/status/ready`, `rpk cluster
maintenance disable <id>`, wait for a healthy, fully replicated cluster.

### Optional hardening (recommended, independent)

Recommended because the `admin` SASL password and the Prometheus scrape key were exposed on
2026-11-06, and because with `admin_api_require_auth=false` any certificate that
`truststore.pem` accepts can act as superuser on 9644 (the legacy-admin-CA leaves remain, e.g.
`prom.crt`). Nothing in the minimal path depends on these steps, in any order.

```shell
scripts/redpanda-admin/generate-admin-password.sh   # secrets/redpanda-admin-password, 0600, never printed
$R $P --tags password       # rotate admin (node cert, auth off) + root rpk profile /root/.config/rpk/rpk.yaml (0600)
$R $P --tags require_auth   # admin_api_require_auth=true, live; refuses unless the file and rpk login work
$R $P --tags verify_auth    # node cert alone: 403 on users/cluster_config/node_config; 200 on ready and metrics
scripts/redpanda-admin/issue-prometheus-scraper-cert.sh   # new EC P-256 scrape cert, prints the kubectl step
```

- After `password`, remove the plaintext copy from `/root/.bash_history` on 195.201.60.99 and
  use `REDPANDA_ADMIN_PASSWORD_FILE=secrets/redpanda-admin-password` for
  `scripts/kafka-client/grant-prefix-access.sh`. Kafka clients logged in as `admin` (see the
  preflight) break at the rotation.
- After `require_auth`, privileged 9644 calls need the admin login as basic auth: rpk as root
  (profile) and `upgrade-cluster.yml` (sends it when the password file exists) keep working;
  a script that POSTs `/v1/security/users` with the node certificate alone (such as
  `create-scram-user.sh`) gets 403. `/public_metrics` and `/metrics` stay open, so the
  Prometheus scrape needs no basic auth. Once auth is on, the minimal path needs the password
  file too (preflight and the restart path read `/v1/node_config` and `/v1/brokers`).
- The scraper script prints a type check of the existing Secret and
  `kubectl --context talos-eu -n prometheus create secret generic redpanda-admin-metrics-client ... --dry-run=client -o yaml | kubectl ... replace -f -`
  (`replace` drops the last-applied annotation that would hold the key). The old key cannot be
  revoked; `require_auth` limits it to the read-only unauthenticated endpoints.
- Rollback: `$R $P --tags rollback_require_auth` (needs the admin login). No return to the
  exposed password.
- **Admin login lost**: copy it back from a broker profile without printing it,
  `(umask 077; ssh root@195.201.61.227 "sed -n 's/^ *password: //p' /root/.config/rpk/rpk.yaml" > secrets/redpanda-admin-password)`.
  With every copy lost while `admin_api_require_auth=true`, no tested path exists.
- `--tags verify` runs `verify_trust` and `verify_auth`. An untagged `--check` covers the
  optional steps too and needs the password file.

### Schema registry and REST proxy (separate, later)

Not part of any run. After the truststore step 8081/8082 accept any legacy-admin-CA
certificate, and with `authentication_method` unset and
`schema_registry_enable_authorization=false` such a client can write schemas. The later step
is `authentication_method: http_basic` on the `schema_registry_api` (and `pandaproxy_api`)
listeners (node config, rolling restart) plus `schema_registry_enable_authorization: true`,
with a SCRAM user and schema registry ACLs per client. Collect the preflight's peer and
operation report first and agree the users with those clients.

## Update (day)

For an existing TLS cluster, run the rolling patch upgrade playbook:

```shell
ansible-playbook --private-key ~/.ssh/id_rsa -i artifacts/hosts.ini ./ansible/upgrade-cluster.yml
```

The default target is `26.2.3-1`. Set `-e redpanda_version=<version>-1` for another patch on the current feature branch. The preflight checks every selected broker and rejects downgrades, feature-release changes, unhealthy membership, incomplete replication, and restart risks. Use `--tags preflight` to run only these read-only checks.

The upgrade repairs the Debian/Ubuntu repository automatically, saves the existing configuration and rollback packages under `/var/backups/redpanda-upgrade-<version>/`, and downloads the new packages before draining the broker. It upgrades one broker at a time, verifies readiness and the running version, exits maintenance mode, and waits for complete replication before continuing. Any failure stops the run; recover and verify that broker before rerunning with `--limit <broker>` or proceeding to another broker. Node configuration and certificates are verified unchanged.

For initial provisioning, keep `redpanda_version` in `ansible/provision-cluster-tls.yml` aligned with the installed version, including the Debian `-1` suffix.

## Dedicated client access (certificate + SCRAM user + prefix ACLs)

Scripted version of the two sections above, for long-lived external clients such as
cait's Mimir. Keys and passwords land in the git-ignored `clients/<name>/` and never
appear in argv or output.

```shell
# 1. 2-year client certificate from ansible/tls/ca_kafka (CN=<name>, O=Coflnet, clientAuth, EC P-256)
scripts/kafka-client/issue-client-cert.sh cait-mimir 730
# 2. SCRAM-SHA-256 user via the admin API (node certificate, no admin password needed)
scripts/kafka-client/create-scram-user.sh cait-mimir
# 3. Owner: pre-create the topic (3 partitions = one per ingester, RF 3, 16 MB messages, 24 h, 50 GB per broker
#    via BUDGET_BYTES) and add prefixed ACLs (topic read/write/describe, group read/describe).
#    Prompts for the admin SASL password.
scripts/kafka-client/grant-prefix-access.sh cait-mimir cait-mimir- cait-mimir-ingest 3
```

The user gets no `create` ACL, so a client cannot add topics that bypass the disk budget;
run it with topic auto-creation off. Each issued certificate's `receipt.txt` holds
`not_after_epoch` for the expiry alert (Fleet `prometheus-rules/kafka-client-cert-expiry-rules.yaml`).
Renew before expiry by issuing a new certificate (new dated folder), hand it over, then
update the alert's timestamp.
