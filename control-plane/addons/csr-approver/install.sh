#!/bin/sh
set -e

helm repo add kubelet-csr-approver https://postfinance.github.io/kubelet-csr-approver
helm --namespace kube-system upgrade \
  --install kubelet-csr-approver kubelet-csr-approver/kubelet-csr-approver \
  --version 1.2.13 \
  --values values.yaml

kubectl -n kube-system wait \
  --for=jsonpath='{.status.phase}'=Running \
  --timeout=5m pod --selector=app.kubernetes.io/name=kubelet-csr-approver
