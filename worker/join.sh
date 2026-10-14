#!/bin/sh
set -e

# for worker nodes

[ -f /etc/containerd/config.toml ] || containerd config default > /etc/containerd/config.toml

# need daemon-reload after editing the service files
systemctl daemon-reload
systemctl start containerd.service

# kubeadm sets staticPodPath on every node but only init creates the directory,
# leaving the kubelet watch logging "path does not exist" once a second
install -m 700 -d /etc/kubernetes/manifests

systemctl start kubelet.service

kubeadm join --config "$(dirname "$0")/kubeadm-join.yaml"

# can enable containerd and kubelet services once everything went well
#systemctl enable containerd.service
#systemctl enable kubelet.service

