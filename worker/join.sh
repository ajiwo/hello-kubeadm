#!/bin/sh
set -e

# for worker nodes

[ -f /etc/containerd/config.toml ] || containerd config default > /etc/containerd/config.toml

# need daemon-reload after editing the service files
systemctl daemon-reload
systemctl start containerd.service
systemctl start kubelet.service

kubeadm join --config "$(dirname "$0")/kubeadm-join.yaml"

# can enable containerd and kubelet services once everything went well
#systemctl enable containerd.service
#systemctl enable kubelet.service

