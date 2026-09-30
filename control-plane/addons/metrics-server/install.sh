#!/bin/sh
set -e

helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm --namespace kube-system upgrade \
  --install metrics-server metrics-server/metrics-server \
  --version 3.14.0 \
  --values values.yaml

kubectl -n kube-system wait \
  --for=jsonpath='{.status.phase}'=Running \
  --timeout=5m pod --selector=app.kubernetes.io/name=metrics-server

