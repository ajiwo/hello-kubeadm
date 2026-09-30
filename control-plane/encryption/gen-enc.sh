#!/bin/sh
set -eu

enc_path=/etc/kubernetes/enc/enc.yaml

if [ -f "$enc_path" ]; then
  echo "skipping: $enc_path already exists"
  exit 0
fi

if [ -z "${KEY1_SECRET:-}" ]; then
  KEY1_SECRET="$(head -c 32 /dev/urandom | base64)"
fi
export KEY1_SECRET

install -m 700 -d /etc/kubernetes/enc
envsubst < "$(dirname "$0")/enc.tpl.yaml" > "$enc_path"
chmod 600 "$enc_path"

echo "generated $enc_path"

