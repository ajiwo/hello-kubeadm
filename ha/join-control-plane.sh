#!/bin/sh
set -e

# for additional control-plane nodes

[ -f /etc/containerd/config.toml ] || containerd config default > /etc/containerd/config.toml

# need daemon-reload after editing the service files
systemctl daemon-reload
systemctl start containerd.service

# kubeadm sets staticPodPath on every node but only init creates the directory,
# leaving the kubelet watch logging "path does not exist" once a second
install -m 700 -d /etc/kubernetes/manifests

# the apiserver mounts this as --encryption-provider-config and exits without
# it, so it has to be copied from the first control-plane before joining
# (see "add a control-plane" in README.md)
[ -f /etc/kubernetes/enc/enc.yaml ] || {
  echo "missing /etc/kubernetes/enc/enc.yaml, copy it from the first control-plane" >&2
  exit 1
}

systemctl start kubelet.service

kubeadm join --config "$(dirname "$0")/kubeadm-join.yaml"

