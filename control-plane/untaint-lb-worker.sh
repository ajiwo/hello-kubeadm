#!/bin/sh
set -e

# worker joins with kubelet cloud-provider=external but no real CCM runs,
# so the uninitialized taint is never cleared
# usage: untaint-lb-worker.sh <node>

[ $# -gt 0 ] || { echo "usage: $0 <node>" >&2; exit 1; }

kubectl taint node "$1" node.cloudprovider.kubernetes.io/uninitialized:NoSchedule-
