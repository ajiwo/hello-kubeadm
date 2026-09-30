#!/bin/sh

set -e

DIR=$(dirname "$0")

[ -f /etc/containerd/config.toml ] || containerd config default > /etc/containerd/config.toml

systemctl daemon-reload
systemctl start containerd.service
systemctl start kubelet.service

"$DIR/encryption/gen-enc.sh"

: > "$DIR/kubeadm-init.log"
chmod 600 "$DIR/kubeadm-init.log"
kubeadm init --config "$DIR/kubeadm-init.yaml" 2>&1 | tee "$DIR/kubeadm-init.log"

mkdir -p /root/.kube
cp -av /etc/kubernetes/admin.conf /root/.kube/config

kubectl -n kube-system patch configmap coredns --patch-file "$DIR/patches/coredns.configmap.yaml"
kubectl -n kube-system patch deployment coredns --patch-file "$DIR/patches/coredns.deployment.yaml"

(cd "$DIR/addons/cilium" && ./install.sh)
(cd "$DIR/addons/csr-approver" && ./install.sh)
(cd "$DIR/addons/metrics-server" && ./install.sh)

# ensure all relevant data are encrypted
kubectl get configmaps,secrets --all-namespaces -o json | kubectl replace -f -

