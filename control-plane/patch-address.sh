#!/bin/sh
set -e

# set ExternalIP on node status so cilium nodeipam advertises it for
# LoadBalancer services. the JSON merge replaces the whole addresses
# array, so InternalIP/Hostname are carried over from the current status.
# requires kubelet --cloud-provider=external, otherwise kubelet rebuilds
# status.addresses on each sync and reverts this.
# usage: patch-address.sh <node> <external-ip>

[ $# -eq 2 ] || { echo "usage: $0 <node> <external-ip>" >&2; exit 1; }

node="$1"
external="$2"

internal="$(kubectl get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
hostname="$(kubectl get node "$node" -o jsonpath='{.status.addresses[?(@.type=="Hostname")].address}')"
existing="$(kubectl get node "$node" -o jsonpath='{.status.addresses[?(@.type=="ExternalIP")].address}')"

[ -n "$internal" ] || { echo "$node: no InternalIP in status" >&2; exit 1; }

if [ "$existing" = "$external" ]; then
  echo "$node: ExternalIP already $external"
  exit 0
fi

addresses="[{\"type\":\"InternalIP\",\"address\":\"$internal\"}"
[ -n "$hostname" ] && addresses="$addresses,{\"type\":\"Hostname\",\"address\":\"$hostname\"}"
addresses="$addresses,{\"type\":\"ExternalIP\",\"address\":\"$external\"}]"

kubectl patch node "$node" --subresource=status --type=merge \
  -p "{\"status\":{\"addresses\":$addresses}}"

kubectl get node "$node" -o jsonpath='{range .status.addresses[*]}{.type}={.address}{"\n"}{end}'
