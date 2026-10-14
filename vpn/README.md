# vpn

optional. run the cluster's node IPs on a routed wireguard interface so nodes reach each other over the tunnel.
wireguard server handling are assumed known (config provided as a hint). only covers what the cluster on top needs.

this is plain wireguard for reachability, not cilium's wireguard encryption
(`encryption.type=wireguard`, [upstream doc](https://github.com/cilium/cilium/blob/v1.20.2/Documentation/security/network/encryption-wireguard.rst)),
which the agent manages on its own `cilium_wg0` interface to transparently encrypt
node-to-node traffic. `wg0` here is NetworkManager-managed and routed, and carries
no cilium state. pick one, not both: `wg0` already encrypts the vxlan traffic
it carries, so cilium's encryption on top just stacks a second tunnel. if you
enable cilium's encryption, skip this path.

## env

| Node | wg0 IP | eth0 IP | Role | externally reachable |
|---|---|---|---|---|
| vpn-server | 10.9.8.1 | 203.0.113.1 | vpn server | yes |
| instance-2 | 10.9.8.2 | | control-plane | no |
| instance-3 | 10.9.8.3 | | worker | no |
| instance-4 | 10.9.8.4 | 10.11.12.14 | worker | yes |

The `eth0` address is not listed for instance-2 and instance-3, it's irrelevant
since all cluster traffic runs over `wg0`, so their underlay address only
needs to reach the vpn-server.

an underlay address must not overlap a cluster-internal range: the node subnet
`10.9.8.0/27` (the `wg0` subnet), the pod CIDR `10.30.0.0/16` (`cilium/values.yaml`),
or the service subnet `10.40.0.0/14` (`kubeadm-init.yaml`).

for instance-2 and instance-3 that is the whole rule. instance-4's is the externally
reachable one nodeipam advertises (see "post-join"), so it also has to stay the same,
see "stable IP addresses" in the main README.

`10.11.12.14` stands in for instance-4's `eth0` address. use whatever your provider
assigns, as long as it does not change. Replace it wherever it appears:
the env table above,
the `patch-address.sh` call in "post-join",
and the `providerIpPrefixes` entry in `vpn/csr-approver-values.yaml`.

## adapting

same table as the main README; `cilium/values.yaml`, `kubeadm-init.yaml` and
`kubeadm-join.yaml` are unchanged. every cluster-facing value keeps its
`10.9.8.x` address, it just lives on `wg0` instead of `eth0`. files of interest:

- `vpn/wg0-client.ini`: per-node private key, server pubkey + endpoint, `wg0` IP,
  and a fresh UUID. see "prep the nodes".
- `vpn/csr-approver-values.yaml`: extra `providerIpPrefixes` entry to merge into
  `control-plane/addons/csr-approver/values.yaml` before running `init.sh`.
  `patch-address.sh` (see "post-join") adds instance-4's `eth0` address to its node
  status, and that address becomes an IP SAN on its kubelet-serving CSR. It falls
  outside the `10.9.8.0/27` `wg0` node subnet, so without the extra entry the CSR
  is not auto-approved; `skipDenyStep` leaves it Pending rather than denying it.
  `init.sh` installs the approver from `values.yaml`, so the merge goes first.
- `example/nodeipam/gateway.yaml`, `example/whoami.yaml`: shared with the main
  README; set the listener hostname in both to the public address your provider
  1:1 NATs to instance-4's `eth0` address (see "gateway address").

## workflow

### prep the vpn-server

the vpn-server is not a cluster node, so it does not get `etc/sysctl.d/90-k8s.conf`.
it forwards between the spokes, so make sure forwarding is on there too:

```sh
# /etc/sysctl.d/90-wg.conf
net.ipv4.ip_forward = 1
```

open UDP `40543` to the server's public address, in the NSG and in the host
firewall if you keep one. the nodes only originate, so nothing else has to be open.

### prep the nodes

On every node, bring up `wg0` first so the node IPs exist when kubeadm runs.
assumes the vpn-server is up and this node is registered on it.
openSUSE Leap Micro 6.2 has no `wireguard-tools` package, so generate the keys
on a machine that has them.

1. generate the keypair:

```sh
touch pri.key
chmod 600 pri.key
wg genkey > pri.key
wg pubkey < pri.key > pub.key
```

2. register the node on the server: add a `[wireguard-peer.<pub.key>]` section to
   `vpn/wg0-server.ini` with `allowed-ips=10.9.8.<n>/32`, then reload it.

3. edit `vpn/wg0-client.ini` for this node:

   - `private-key=` ->contents of `pri.key`
   - `[wireguard-peer.<server-pubkey>]` ->the server's public key
   - `endpoint=` ->your server's public address, e.g. `203.0.113.1:40543`
   - `address1=10.9.8.<n>/27` ->this node's `wg0` IP
   - `uuid=` ->a fresh `uuidgen`

4. install and bring it up:

```sh
install -m 600 -o root -g root vpn/wg0-client.ini \
  /etc/NetworkManager/system-connections/wg0.nmconnection
nmcli connection reload
nmcli connection up wg0
```

5. verify the tunnel is up:

```sh
ping -c 3 10.9.8.1     # vpn-server wg0 IP (see "env")
ping -c 3 10.9.8.<n>   # another node's wg0 IP, once it is up
```

if the server does not answer, the tunnel isn't routing. fix it before running
kubeadm. a node that isn't up yet may not answer, that's expected.

### post-join: nodeipam

same as the main README, then patch instance-4's ExternalIP so nodeipam
advertises its reachable `eth0` address instead of the `wg0` node IP:

```sh
control-plane/exclude-lb.sh instance-2 instance-3
control-plane/untaint-lb-worker.sh instance-4
control-plane/patch-address.sh instance-4 10.11.12.14  # <-extra step here
```

## verification

confirm cilium picked up `wg0`:

```sh
kubectl -n kube-system exec -it ds/cilium -- cilium-dbg status
```

```
KubeProxyReplacement: True [enp0s6 192.168.72.21 2xxx:xxxx:..., wg0 10.9.8.2 (Direct Routing)]
Routing:              Network: Tunnel [vxlan]   Host: Legacy
```

the datapath stays in plain tunnel mode (vxlan): pod traffic is encapsulated to
the node IPs, and the kernel then routes those outer packets over `wg0` per its
own routing table. that is the tunnel's only interaction with `wg0`.

the `(Direct Routing)` marker names Cilium's direct routing device: the single
device it uses to reach other cluster nodes, and whose address it borrows as the
source IP for traffic it originates on behalf of a Service. BPF NodePort and host
routing use it too ([source](https://github.com/cilium/cilium/blob/v1.20.2/pkg/datapath/tables/direct_routing_device.go#L27-L35)),
and its address is compiled into the datapath as `IPV4_DIRECT_ROUTING`
([source](https://github.com/cilium/cilium/blob/v1.20.2/pkg/datapath/linux/config/config.go#L364-L372)).

when more than one device is detected, Cilium picks one
([upstream source](https://github.com/cilium/cilium/blob/v1.20.2/Documentation/network/kubernetes/kubeproxy-free.rst#L1380-L1392),
[selection source](https://github.com/cilium/cilium/blob/v1.20.2/pkg/datapath/tables/direct_routing_device.go#L61-L98)):

1. `nodePort.directRoutingDevice`, if set. not set here.
2. the sole detected device, if only one. not the case, `enp0s6` and `wg0` are both listed.
3. otherwise the device holding the node IP, InternalIP preferred over ExternalIP.

step 3 is what fires here: the node IP `10.9.8.2` is a `wg0` address. `node-ip`
is the only input - keep it on the other device (`enp0s6` above) and the marker
moves there, with the same vxlan datapath and the same outer packets riding `wg0`.

the device choice and the routing mode are separate knobs that happen to share a
name. `enable-auto-direct-routing` is the datapath-level one, and it is refused
outright when tunneling is on
([source](https://github.com/cilium/cilium/blob/v1.20.2/daemon/cmd/daemon_main.go#L1066-L1068)),
so it is off under `Tunnel [vxlan]`.

### gateway address

then confirm the LoadBalancer path points at the externally reachable node.
apply the Gateway with the listener hostname set to the public address your
provider 1:1 NATs to instance-4's `eth0` address:

```sh
kubectl apply -f example/nodeipam/gateway.yaml
kubectl -n kube-public get gateway common
```

the address is instance-4's `eth0` address (`10.11.12.14`), not its `wg0` node IP.
this is the one place the vpn topology shows up in the cluster output, `patch-address.sh`
added an ExternalIP to instance-4's node status, and nodeipam prefers ExternalIP over InternalIP.
instance-2 and instance-3 carry `node.kubernetes.io/exclude-from-external-load-balancers`,
so instance-4 is the only node advertising, and its ExternalIP wins.

this does not happen instantly. if `get gateway common` shows no address yet, or
a later step misbehaves, give it a moment and retry before digging. the
under-the-hood wiring (nodeipam, cilium LB) takes time to settle, nothing is
broken just because it hasn't shown up yet.

before adding a route, curl the public endpoint. it should answer with 404: the
gateway answers but no route matches yet.

```sh
curl -v http://<your-public-address>/
```

if this doesn't return 404, investigate and fix before continuing, so a broken
gateway path isn't mistaken for a broken whoami.

full path, from the workstation:

```sh
kubectl apply -f example/whoami.yaml
kubectl -n whoami wait --for=condition=Available deploy/hello --timeout=30s
curl http://<your-public-address>/
```

cleanup:

```sh
kubectl delete -f example/nodeipam/gateway.yaml -f example/whoami.yaml
```

