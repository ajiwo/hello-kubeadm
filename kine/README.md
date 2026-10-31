# kine

Optional: replace etcd with kine for a SQL-backed Kubernetes datastore.

## Setup

1. Download the binary:

uncomment the kine block in `download/download.sh`
([lines 61-68](../download/download.sh#L61-L68)) and re-run the download before
distributing `dist/`.

if you'll want the `etcdctl` check further down, also uncomment the etcd block
([lines 48-59](../download/download.sh#L48-L59)).

2. Create the kine user and directories:

```sh
useradd -r -s /sbin/nologin kine
mkdir -p /var/lib/kine/tls
chmod 700 /var/lib/kine
chmod 750 /var/lib/kine/tls
chown kine:kine /var/lib/kine
chown root:kine /var/lib/kine/tls
```

3. Set up mutual TLS, you'll need:

- **kine CA** (`kine-ca.crt`) signs the server certs, trusted by kube-apiserver
- **kine server certs** (`kine-server-1.crt`, `kine-server-1.key`) served by kine on `:2379`
- **client certs** (`kine-client-1.crt`, `kine-client-1.key`) used by kube-apiserver to connect to kine
- **database CA** (`pg-ca.crt`)  if Postgres/MySQL uses TLS

place them in `/var/lib/kine/tls/`. we assume you know how to generate or obtain these.

4. Configure `/etc/sysconfig/kine`:

```ini
KINE_LISTEN_ADDRESS=0.0.0.0:2379
KINE_SERVER_CERT_FILE=/var/lib/kine/tls/kine-server-1.crt
KINE_SERVER_KEY_FILE=/var/lib/kine/tls/kine-server-1.key
KINE_TRUSTED_CA_FILE=/var/lib/kine/tls/kine-ca.crt
KINE_ENDPOINT="postgresql://kine_user:kine_password@your-db-host:5432/kine_db?sslmode=verify-full"
KINE_CA_FILE=/var/lib/kine/tls/pg-ca.crt
```

5. Install the systemd unit:

```sh
cp kine.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now kine
```

6. Point kubeadm at kine instead of local etcd:

```sh
kubeadm init --config kubeadm-init.yaml \
  --ignore-preflight-errors=ExternalEtcdVersion
```

the adjustment file overrides the `etcd.external` section to point at kine's endpoint with TLS.

the flag is required. kubeadm's `ExternalEtcdVersion` preflight does an HTTP `GET <endpoint>/version`, but kine
serves gRPC only on :2379 and has no `/version` handler since
[f2d9e5d](https://github.com/k3s-io/kine/commit/f2d9e5d0c6a04604c5e0089df664adde21433de6), so the check fails with
`Get "https://<host>:2379/version": EOF`. `--ignore-preflight-errors=ExternalEtcdVersion` demotes this to a
warning ([source](https://github.com/kubernetes/kubernetes/blob/v1.37.2/cmd/kubeadm/app/preflight/checks.go#L760-L788));
it does not affect kube-apiserver's gRPC access to kine.

query the kine endpoint directly with the host-side `etcdctl` from the download step:

```sh
etcdctl --endpoints=https://10.9.8.2:2379 \
  --cacert=/var/lib/kine/tls/kine-ca.crt \
  --cert=/var/lib/kine/tls/kine-client-1.crt \
  --key=/var/lib/kine/tls/kine-client-1.key \
  endpoint status -w json
```

## Supported databases

certified versions ([source](https://github.com/k3s-io/docs/raw/f6d5b17d97e5160706ed56c405b6b17cf9d826af/docs/datastore/datastore.md)):

- PostgreSQL 15.12, 16.7, 17.3
- MySQL 8.0, 8.4
- MariaDB 10.11, 11.4
- etcd 3.5.21

**Watch out:**
- init still prints `[WARNING ExternalEtcdVersion]: Get "...": EOF`. the flag demotes the error to a warning instead of suppressing it ([source](https://github.com/kubernetes/kubernetes/blob/v1.37.2/cmd/kubeadm/app/preflight/checks.go#L1212-L1216)). expected, not a second failure
- the ignore is safe only while that check stays a version floor. if kubeadm adds real compatibility probing to it, drop the flag and re-read the reasoning above
- stick to the certified versions above, unsupported versions can cause compaction failures and other issues ([kine#745](https://github.com/k3s-io/kine/issues/745))
- connection poolers like PgBouncer need extra config for prepared statements
- multi-master setups (Galera, etc.) with `auto_increment_increment` > 1 are not supported, kine expects revisions to start at 0 and increment by exactly 1

