# ha

optional. run an odd number of control-planes so the apiserver and etcd survive a
control-plane node failure. workers are unaffected.

the control-planes sit behind a load balancer the nodes reach by a name that resolves
everywhere. provisioning that load balancer is outside this repo, so the overlay gets you
redundant members. the endpoint survives a failure once the load balancer's health check
drops the dead node. kubeadm lists the options: keepalived+haproxy, or kube-vip as a
static pod on the control-planes ([ha-considerations](ref.txt)).

the join path needs `--upload-certs` on the first `kubeadm init`, which
`control-plane/init.sh` already passes.

## env

| Node | IP | Role | externally reachable |
|---|---|---|---|
| instance-2 | 10.9.8.2 | first control-plane | no |
| instance-3 | 10.9.8.3 | worker | no |
| instance-4 | 10.9.8.4 | worker | yes |
| instance-5 | 10.9.8.5 | control-plane | no |
| instance-6 | 10.9.8.6 | control-plane | no |

prep instance-5 and instance-6 like any node, steps 1-3 of the main README. keep the
control-plane count odd, etcd needs a majority to make progress.

## adapting

| File | What to change |
|---|---|
| `control-plane/kubeadm-init.yaml` | `controlPlaneEndpoint` to the load balancer name (see below) |
| `control-plane/addons/cilium/values.yaml` | `k8sServiceHost` to the load balancer name |
| `worker/kubeadm-join.yaml` | `discovery.bootstrapToken.apiServerEndpoint` to the load balancer name |
| `ha/kubeadm-join.yaml` | per-node name, IP, token, CA hash, certificate key |

`ha/kubeadm-init.yaml` shows the init change, `ha/cilium-values.yaml` the cilium one.

### the load balancer name

`kapisrv.lb.example.com` stands in for the load balancer address. this setup needs a name
here: the step below resolves it per node.
upstream docs on the kube-apiserver load balancer
([source](https://github.com/kubernetes/website/blob/be44f0fb4230bec1dd3e0ecce420fb52ab8faea3/content/en/docs/setup/production-environment/tools/kubeadm/high-availability.md?plain=1#L125-L143)).
kubeadm writes it into every kubeconfig it generates, so workers and kubelets follow the
same endpoint.

you do not need the load balancer yet. fake the name in `/etc/hosts` on each node so the
first control-plane can init and the rest can join one that is already up:

| Node | `/etc/hosts` entry | why |
|---|---|---|
| instance-2 | `10.9.8.2 kapisrv.lb.example.com` | before init, points at itself |
| instance-5 | `10.9.8.2 kapisrv.lb.example.com` | joins the first control-plane |
| instance-6 | `10.9.8.5 kapisrv.lb.example.com` | joins the second control-plane |
| instance-3, instance-4 | `10.9.8.6 kapisrv.lb.example.com` | joins the last control-plane |

the table assumes workers join last, after instance-6 is up. if you join them
earlier, point them at whichever control-plane is already up.

`init.sh` runs kubectl against the endpoint right after init, so the entry has to be in
place before it starts.

this is not HA while the entry is static: every node follows one control-plane, and that
one going down takes the name with it. it only gets you through bootstrap.

kubelet gives a hostNetwork pod the node's `/etc/hosts`
([source](https://github.com/kubernetes/kubernetes/blob/v1.37.2/pkg/kubelet/kubelet_pods.go#L497-L504)),
so the cilium agent resolves it too.

kubeadm adds this name and each node's own advertise address and name to the apiserver
serving certs
([source](https://github.com/kubernetes/kubernetes/blob/v1.37.2/cmd/kubeadm/app/util/pkiutil/pki_helpers.go#L384-L424)),
so `certSANs` needs an entry only for a name or IP you reach the apiservers by that is
not one of those.

## workflow

build the first control-plane with the main README (step 4) after the `adapting` changes,
then add the rest here.

### add a control-plane

join control-planes one at a time, after the previous one is fully up.

1. copy the encryption key from the first control-plane, the joining apiserver mounts it
   as `--encryption-provider-config` and exits without it:

```sh
# on the joining node
install -d -m 700 /etc/kubernetes/enc
```

```sh
# on the first control-plane, instance-5 stands in for the joining node
scp /etc/kubernetes/enc/enc.yaml instance-5:/etc/kubernetes/enc/enc.yaml
```

2. edit `ha/kubeadm-join.yaml` for this node: `nodeRegistration.name`,
   `nodeRegistration.kubeletExtraArgs` node-ip, `controlPlane.localApiEndpoint`, and the
   token, CA hash and certificate key from the first `kubeadm-init.log`.

3. on the joining node:

```sh
ha/join-control-plane.sh
```

the certificate key decrypts the certs the first control-plane uploaded, and expires
after two hours. re-upload and mint a new one on the first control-plane if that runs out
before the rest joined:

```sh
kubeadm init phase upload-certs --upload-certs
```

### after all control-planes joined

check etcd membership from the first control-plane, every control-plane must be listed:

```sh
kubectl -n kube-system exec etcd-instance-2 -c etcd -- etcdctl member list -w table
```

scale the control-plane add-ons. the main path pins cilium-operator to 1, and the two
CoreDNS replicas start stacked on the first node:

```sh
kubectl -n kube-system scale deployment cilium-operator --replicas=2
kubectl -n kube-system rollout restart deployment coredns
```

the CoreDNS replicas tolerate the control-plane taint and spread once more than one
control-plane is schedulable
([source](https://github.com/kubernetes/website/blob/be44f0fb4230bec1dd3e0ecce420fb52ab8faea3/content/en/docs/setup/production-environment/tools/kubeadm/high-availability.md?plain=1#L267-L271)).

## verification

hit each apiserver on its own address. each must return the node list without a TLS or
hostname error, which also proves the address is in that apiserver's cert:

```sh
kubectl --server https://10.9.8.2:6443 get nodes
kubectl --server https://10.9.8.5:6443 get nodes
kubectl --server https://10.9.8.6:6443 get nodes
```

once these pass, add 10.9.8.2, 10.9.8.5 and 10.9.8.6 on 6443 as load balancer backends,
then remove the static `/etc/hosts` entry so the name follows the load balancer. if the
name has no DNS, point the entry at the load balancer's address instead of removing it.

to confirm the endpoint survives a control-plane failure, run kubectl against the load
balancer name on 6443 (or point your kubeconfig at it), disrupt one control-plane, then
retry kubectl. a successful response means the load balancer dropped the dead backend and
the remaining control-planes still answer.
