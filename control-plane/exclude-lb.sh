#!/bin/sh
set -e

# label nodes cilium nodeipam must skip when advertising LoadBalancer node IPs
# usage: exclude-lb.sh <node> [node...]

[ $# -gt 0 ] || { echo "usage: $0 <node> [node...]" >&2; exit 1; }

for node in "$@"; do
  kubectl label node "$node" node.kubernetes.io/exclude-from-external-load-balancers=
done
