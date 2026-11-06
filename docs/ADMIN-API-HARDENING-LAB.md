# Admin API hardening: lab evidence (2026-11-06)

Evidence for `ansible/harden-admin-auth.yml` and the README section "Admin API hardening".
No production broker, cluster or secret was used.

## Setup

- Redpanda **v26.2.6** (`redpandadata/redpanda:v26.2.6` plus python3/iproute2 so Ansible can
  run inside the containers). Three brokers, each `docker run --memory 2g --cpus 2` with
  `--smp 1 --memory 1G --reserve-memory 0M --overprovisioned`, on a private bridge network.
- Synthetic PKI with the production layout: legacy admin CA (RSA-2048,
  `CN=Coflnet GmbH, O=Coflnet`, pathlen 0), legacy Kafka CA (RSA-2048, **the same subject
  DN**), shared root (EC P-384, `CN=Coflnet Internal Root CA`, pathlen 1) with an EC P-384
  intermediate. Node certificates come from the legacy CAs (serverAuth + clientAuth, IP SANs).
  Clients: legacy-admin-CA leaf, shared-root leaf (sent with its intermediate), Kafka-CA leaf.
- Broker configuration mirrors production: `admin_api_tls`, `schema_registry_api_tls`,
  `pandaproxy_api_tls` and `rpc_server_tls` use `node.crt` + `truststore.pem`
  (legacy admin CA + shared root), `kafka_api_tls` uses `node_kafka.crt` +
  `truststore_kafka.pem` (legacy Kafka CA + shared root), all with `require_client_auth`.
  The `rpk` section uses the node certificates and has no SASL. Cluster config:
  `enable_sasl=true`, `sasl_mechanisms=[SCRAM]`, `superusers=[admin]`,
  `admin_api_require_auth=false`, `schema_registry_enable_authorization=false`.
- The playbook ran from this branch against the containers through an inventory that
  overrides only the connection (`community.docker.docker`), the pins (lab CA hashes), the
  password file path, the PID command and `redpanda_restart_mode: docker`.

## Results

| # | Test | Result |
|---|------|--------|
| 1 | Rotate `admin` via `PUT /v1/security/users/admin` with the node certificate only, auth off | 200 on the controller leader; a non-leader answers **307** to the leader (`follow_redirects: all` in Ansible's `uri` resends method, body and client certificate). Old password refused over SASL right after, new one accepted |
| 2 | Basic auth while `admin_api_require_auth=false` | **Not validated**: a wrong password still gets 200. The password can only be proven over Kafka SASL before auth is on (the playbook does) |
| 3 | rpk profile `/root/.config/rpk/rpk.yaml` (`kafka_api.sasl` + TLS, `admin_api` + TLS) | rpk 26.2 reads it before `redpanda.yaml` and sends the SASL user/password as admin API basic auth. rpk rewrites the file (adds `license_check`) but keeps mode 0600; the playbook compares the semantics, so reruns stay `changed=0` |
| 4 | `admin_api_require_auth=true` via `PUT /v1/cluster_config` (`upsert` + `remove: []`) | Applied live on all brokers, `restart: false` in `/v1/cluster_config/status` |
| 5 | rpk with the profile after require_auth | `cluster config get`, `cluster health`, `security user list`, `security acl list`, `cluster maintenance enable --wait` / `disable`: all OK. Without the profile: `Forbidden (superuser role required)` |
| 6 | Endpoints without basic auth after require_auth (node cert, legacy-admin-CA client, new scraper cert) | `/public_metrics` **200**, `/metrics` **200**, `/v1/status/ready` 200, `/v1/cluster/health_overview` 200, `/v1/broker/pre_restart_probe` 200, `/v1/cluster/uuid` 200, `/v1/features/license` 200. `/v1/brokers`, `/v1/partitions`, `/v1/cluster_view`, `/v1/features`, `/v1/usage`, `/v1/transactions` **401**. `/v1/node_config`, `/v1/cluster_config(/status)`, `/v1/security/users`, `/v1/loggers` **403** |
| 7 | Mutations without basic auth after require_auth (legacy-admin-CA client) | `PUT /v1/cluster_config` (superusers) 403, `POST /v1/security/users` 403, `DELETE /v1/security/users/x` 403, `PUT /v1/brokers/2/maintenance` 403, `PUT /v1/config/log_level/...` 403, `POST /v1/partitions/rebalance` 403, `PUT /v1/features/license` 403 |
| 8 | Metrics with a wrong basic-auth password after require_auth | `/public_metrics`, `/metrics` still 200 (credentials ignored); `/v1/status/ready`, `health_overview` **401** (credentials validated when sent) |
| 9 | Prometheus scrape cert from `issue-prometheus-scraper-cert.sh` (lab CA; refuses a CA key that does not match `ca.crt`, a wrong CA fingerprint and an existing dated directory) | `/public_metrics` 200 with 2310 `redpanda_*` series; `/v1/security/users`, `/v1/cluster_config`, `/v1/node_config` 403; `PUT /v1/cluster_config` 403 |
| 10 | Truststore replacement (rename, as Ansible `copy` does) on a freshly started broker | Reloaded live within 1-2 s by admin, rpc (server + client), schema_registry and rest_proxy; `vectorized_tls_trust_file_crc32c{area=...}` shows the new CRC32C; kafka area unchanged; same process |
| 11 | **A later replacement** (rollback after a forward run, 2-4 min later) | **Partly ignored**: twice reproduced, only `admin` (once) or only the RPC client (once) reloaded; rpc server, schema_registry and rest_proxy kept the old trust until restart, `touch` did not help. Quick successive replacements (seconds apart, by shell) always reloaded. Root cause not found (Seastar file watcher). The playbook therefore checks every listener's CRC32C (all shards, any `detail` label) and, after a confirmation (terminal prompt, or `-e harden_confirm_restart=<broker>`), restarts that broker through maintenance mode when one stays stale for 30 s; the fallback ran once in the lab (node 0, rollback) and converged |
| 12 | Shared-root client after the change | TLS refused on 9644, 8081 and 8082 (`alert unknown ca`) |
| 13 | Legacy-admin-CA client after the change | TLS accepted on 9644/8081/8082; 403 on privileged admin endpoints |
| 14 | Internode RPC with legacy-only `truststore.pem` on all three brokers | Restarts of broker 2, 0 and 1 (fresh RPC connections both ways): rejoined, healthy, 0 under-replicated, RF-3 topic readable |
| 15 | Kafka 9092 after the change | Shared-root leaf + SCRAM: accepted (consumed). Kafka-CA leaf + SCRAM: accepted. Shared-root leaf without SASL: refused (SASL required). Legacy-admin-CA leaf: TLS refused (as before) |
| 16 | Playbook `--tags preflight`, `--check` (start state and hardened state) | rc 0; check mode changes nothing (no file, no backup dir, no config change) |
| 17 | Playbook steps `password`, `require_auth`, `truststore`, `verify` in owner order on a fresh cluster (second round, after review fixes) | rc 0 each; `password` rerun reports "no rotation", `changed=0`; `truststore` ran one broker at a time, all three "reloaded live" |
| 17a | Guards | Untagged real run refused (rc 2, nothing changed). `--tags require_auth` before `--tags password` refused before the config PUT (no rpk login yet). `require_auth` also proves the controller file over SASL before locking |
| 17c | Fallback restart task run directly on broker 2 | Confirmation off: pre-restart probe, drain, restart, ready, alive, maintenance off, healthy. Confirmation on with stdin `/dev/null`: stops with "Restart not confirmed" before draining |
| 17d | Round 3 guards (fresh cluster) | `--tags password --limit A` and `--tags truststore --limit B`: refused, nothing changed. `--tags truststore --skip-tags preflight`: refused (no pinned CA facts). Symlinked `truststore.pem`: refused before the copy. `rollback_truststore --limit A`: allowed |
| 17e | Fallback restart with `docker restart` failing (pass-through shim) | Drain done, restart failed, rescue ran `rpk cluster maintenance disable`, run stopped; afterwards no node in maintenance, cluster healthy |
| 17f | `rpk cluster maintenance enable --wait` / `disable` with `admin_api_require_auth=true`, run on broker 1 (not the controller) for node 2, node 0 (controller) and node 1 | All succeeded. rpk sends basic auth to its local admin address; `PUT /v1/brokers/2/maintenance` on broker 1 answers **200 with no redirect** (forwarded internally), so the Go client's dropping of Authorization on cross-host redirects does not apply. `rpk cluster maintenance status` can lag a few seconds after `disable` |
| 17g | `scripts/redpanda-admin/run-with-pinned-host-keys.sh` (no SSH) | Prints `host key <ip>: found/missing` per inventory broker from `~/.ssh/known_hosts` (`ssh-keygen -F`, also hashed entries) and refuses if one is missing; otherwise runs with host_key_checking=True, `BatchMode=yes`, `StrictHostKeyChecking=yes`, that known_hosts and its own control-socket directory (checked with `lookup('config')`) |
| 17h | **Minimal path from a fresh start** (overlap truststores, `admin_api_require_auth=false`, no password file, no rpk profile), runs with stdin `/dev/null` | `--tags preflight` rc 0; `--check --tags truststore,verify_trust` rc 0, nothing changed; `--tags truststore -e harden_truststore_restart=always -e harden_confirm_restart=10.213.106.10`: broker .10 restarted through maintenance (drain/undrain by rpk with the node certificate), broker .11 stopped with "not confirmed" before its drain, no node left in maintenance; rerun `--tags truststore` (auto) converged .11 and .12 live; `--tags verify_trust` rc 0 |
| 17i | Minimal-path rollback and re-apply (same conditions) | `rollback_truststore -e harden_truststore_restart=always` without a terminal or confirmation: stopped before the drain; `rollback_truststore` (auto): all reloaded live; `truststore` again: all reloaded live; `verify_trust` rc 0; `--check --tags truststore,verify_trust` in the end state: nothing changed. No password file or rpk profile existed at any point |
| 17j | Optional steps on top of the minimal path | `password`, `require_auth`, `verify` (trust + auth), `truststore` rerun with auth on (`changed=0`), untagged `--check` (`changed=0`): all rc 0 |
| 17b | Preflight usage report | Shows peers per port (9644/8081/8082, `ss`) and the source IPs of recent Kafka connections authenticated as `admin` (`rpk cluster connections list`, admin API v2) |
| 18 | `--tags rollback_truststore`, `--tags rollback_require_auth`, then forward again | rc 0 (after the fallback in row 11 was added); node certificate alone gets 200 on `/v1/security/users` again after the auth rollback |
| 18a | Recovery copy of the password from a broker profile (README "Recovery") | `sed -n 's/^ *password: //p' /root/.config/rpk/rpk.yaml` yields a byte-identical file (`cmp`) |
| 19 | `upgrade-cluster.yml` preflight admin API tasks against the locked API | Unpatched: **403** on `/v1/node_config`. Patched (basic auth from the password file): passes |
| 20 | Secret hygiene | The password never appears in 21 playbook logs (`grep -F -f`); it is only in the 0600 controller file and root's 0600 rpk profile |
| 21 | Schema registry with `authentication_method` none, authorization false | Any certificate the truststore accepts can write schemas (earlier lab, same day); the hardening does not change this |

The preflight reports, per broker, established 8081/8082 peers (`ss`) and the schema
registry / REST proxy operations with non-zero counters since the broker started
(`vectorized_pandaproxy_request_latency_count{operation=...}`). Redpanda does not log
HTTP clients at info level, so these two are the only usage signals.

Not tested: systemd restarts (the lab restarts containers), SASL mechanisms other than
SCRAM-SHA-256, more than one shard per broker (the lab flags fix `--smp 1`; the checks match
every `shard` label, but production's per-shard series layout is unverified), the real
OpenBao-issued shared-root leaves, an interrupted truststore run (preflight accepts
"file legacy-only, listeners stale" only under `--tags truststore`), offline recovery
without any copy of the admin password.
