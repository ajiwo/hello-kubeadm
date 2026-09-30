#!/bin/sh
set -e

# https://docs.cilium.io/en/v1.20/network/servicemesh/gateway-api/gateway-api/

#kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.6.1/config/crd/standard/gateway.networking.k8s.io_gatewayclasses.yaml
#kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.6.1/config/crd/standard/gateway.networking.k8s.io_gateways.yaml
#kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.6.1/config/crd/standard/gateway.networking.k8s.io_httproutes.yaml
#kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.6.1/config/crd/standard/gateway.networking.k8s.io_referencegrants.yaml
#kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.6.1/config/crd/standard/gateway.networking.k8s.io_grpcroutes.yaml
#kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.6.1/config/crd/standard/gateway.networking.k8s.io_backendtlspolicies.yaml
#kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.6.1/config/crd/standard/gateway.networking.k8s.io_tlsroutes.yaml
#kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.6.1/config/crd/standard/gateway.networking.k8s.io_listenersets.yaml
#kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.6.1/config/crd/standard/gateway.networking.k8s.io_tcproutes.yaml
#kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.6.1/config/crd/standard/gateway.networking.k8s.io_udproutes.yaml

# standard gateway-api v1.6.1 CRDs, cached locally
kubectl apply -f gateway-crds.yaml

cilium install --version 1.20.1 --values values.yaml 

kubectl -n kube-system wait \
  --for=jsonpath='{.status.phase}'=Running \
  --timeout=5m pod --selector=app.kubernetes.io/name=cilium-agent

