# kine

Optional: replace etcd with kine for a SQL-backed Kubernetes datastore.

## Setup

1. Download the binary:

```sh
curl -LO https://github.com/k3s-io/kine/releases/download/v0.17.0/kine-arm64
curl -LO https://github.com/k3s-io/kine/releases/download/v0.17.0/sha256sum-arm64.txt
sha256sum -c sha256sum-arm64.txt
chmod +x kine-arm64
mv kine-arm64 /usr/local/bin/kine
```

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
kubeadm init --config kubeadm-init.yaml ...
```

the adjustment file overrides the `etcd.external` section to point at kine's endpoint with TLS.

## Supported databases

certified versions ([source](https://github.com/k3s-io/docs/raw/f6d5b17d97e5160706ed56c405b6b17cf9d826af/docs/datastore/datastore.md)):

- PostgreSQL 15.12, 16.7, 17.3
- MySQL 8.0, 8.4
- MariaDB 10.11, 11.4
- etcd 3.5.21

**Watch out:**
- Stick to the certified versions above, unsupported versions can cause compaction failures and other issues ([kine#745](https://github.com/k3s-io/kine/issues/745))
- Connection poolers like PgBouncer need extra config for prepared statements
- Multi-master setups (Galera, etc.) with `auto_increment_increment` > 1 are not supported, kine expects revisions to start at 0 and increment by exactly 1

