# hello-kubeadm

kubernetes bootstrap using kubeadm on plain VMs or baremetals. more of a set of notes than a turnkey script.

## Ingredients

| Component | Version | Notes |
|---|---|---|
| kubeadm / kubelet / kubectl | v1.37.0 | |
| containerd | v2.3.4 | runtime |
| runc | v1.4.3 | |
| crictl | v1.36.0 | |
| Cilium CLI | v0.20.1 | installs Cilium |
| Cilium | v1.20.1 | CNI, replaces kube-proxy |
| Gateway API | v1.6.1 CRDs | standard profile via Cilium |
| kubelet-csr-approver | v1.2.13 | Helm chart |
| metrics-server | v3.14.0 | Helm chart |
| Helm | v4.2.3 | |

All binaries land in `/usr/local`. the components above are never installed from distribution packages. the scripts still use
ordinary host tools, to check:

```sh
for c in systemctl tee cp chmod mkdir rm install dirname sha256sum head \
         mktemp cat base64 sed envsubst curl tar gpg; do
  command -v "$c" >/dev/null || echo "missing: $c"
done
```

## Environment

Single control-plane, two workers, Linux arm64, Linux distribution with systemd.

| Node | IP | Role | externally reachable |
|---|---|---|---|
| instance-2 | 10.9.8.2 | control-plane | no |
| instance-3 | 10.9.8.3 | worker | no |
| instance-4 | 10.9.8.4 | worker | yes |

intentionally hardcoded, adapt to your environment.

Tested on openSUSE Leap Micro 6.2 and RHEL 10.

## Adapting to your environment

files with hardcoded values you'll need to change:

| File | What to change |
|---|---|
| `control-plane/addons/cilium/values.yaml:16` | pod CIDR, must equal `kubeadm-init.yaml:40` |
| `control-plane/addons/cilium/values.yaml:25-26` | `k8sServiceHost` / `k8sServicePort` API server |
| `control-plane/addons/csr-approver/values.yaml:9` | `providerRegex` node hostname pattern |
| `control-plane/addons/csr-approver/values.yaml:13` | `providerIpPrefixes` node subnet |
| `control-plane/kubeadm-init.yaml:5` | `advertiseAddress` control-plane IP |
| `control-plane/kubeadm-init.yaml:9` | `nodeRegistration.name` control-plane hostname |
| `control-plane/kubeadm-init.yaml:20-21` | `certSANs` control-plane IP and hostname |
| `control-plane/kubeadm-init.yaml:34` | `controlPlaneEndpoint` control-plane endpoint |
| `control-plane/kubeadm-init.yaml:40-41` | `podSubnet` / `serviceSubnet`, `podSubnet` must equal `cilium/values.yaml:16` |
| `control-plane/patches/coredns.configmap.yaml:17-19` | hosts block your node IPs and hostnames |
| `download/download.sh:5` | set to `amd64` for `x86_64` |
| `worker/kubeadm-join.yaml:4,7,9-10,14,16` | node name, IP, cloud-provider (instance-4 only), token, CA hash |


## Workflow

### 1. Prep the nodes

On every node, load kernel modules and enable IP forwarding:

```sh
# /etc/modules-load.d/90-k8s.conf
overlay
br_netfilter
```

```sh
# /etc/sysctl.d/90-k8s.conf
net.ipv4.ip_forward = 1
```

the config files are in `etc/`.

disable swap.

if your VPS provider has a network security group (NSG), set it up before going further:
allow 22/tcp from your own address, plus whatever ports you need yourself.
nothing cluster-facing has to be open yet, the nodes only talk to each other over the private network.
leave outbound unrestricted, image pulls need it.

the NSG and the host firewall below are separate gates, a quiet drop can come from either.

disable the host firewall. if you know what you're doing, you can keep it enabled by opening the right ports and source/dest ranges ([upstream source](https://github.com/kubernetes/website/raw/a199ec8be7360da84d69687e9c16710f462194a2/content/en/docs/reference/networking/ports-and-protocols.md)).

set SELinux to permissive. effectively off, needed until kubelet SELinux support improves, since some CNI plugins need containers to reach the host filesystem. if you know what you're doing, you can leave it enforcing and do the labeling yourself ([upstream source](https://github.com/kubernetes/website/blob/a199ec8be7360da84d69687e9c16710f462194a2/content/en/docs/setup/production-environment/tools/kubeadm/install-kubeadm.md?plain=1#L279-L286)).

### 2. Download binaries

on a machine with internet access:

```sh
download/download.sh
```

this pulls containerd, k8s binaries, Cilium CLI, Helm, crictl, and runc into `download/dist/`. checksums are verified. runc is gpg-verified instead.

`ARCH` is set to `arm64` on [line 5](download/download.sh#L5). change to `amd64` if needed.

### 3. Distribute files to nodes

copy `download/dist/` contents to each node:

```txt
download/dist/
  usr/local/bin/             -> /usr/local/bin/
  usr/local/libexec/cni/bin/ -> /usr/local/libexec/cni/bin/
  etc/systemd/system/        -> /etc/systemd/system/
    containerd.service
    kubelet.service
    kubelet.service.d/
      10-kubeadm.conf
```

also copy the kernel module, sysctl, and containerd configs:

```txt
etc/modules-load.d/90-k8s.conf -> /etc/modules-load.d/90-k8s.conf
etc/sysctl.d/90-k8s.conf       -> /etc/sysctl.d/90-k8s.conf
etc/containerd/conf.d/k8s.toml -> /etc/containerd/conf.d/k8s.toml
```

on each node, run `systemctl daemon-reload` after copying service files.

### 4. Init the control-plane

on the control-plane node (instance-2):

```sh
./control-plane/init.sh
```

this does, roughly, in order:

1. starts containerd + kubelet
2. generates encryption key at `/etc/kubernetes/enc/enc.yaml` (skips if exists)
3. runs `kubeadm init` with `kubeadm-init.yaml` (skips the kube-proxy addon, Cilium replaces it)
4. copies admin kubeconfig to `/root/.kube/config`
5. patches CoreDNS (custom hosts, relaxed liveness probe)
6. installs Cilium CNI + Gateway API CRDs
7. installs kubelet-csr-approver (auto-approves kubelet-serving CSRs)
8. installs metrics-server via Helm
9. re-encrypts all existing Secrets and ConfigMaps

join token and CA cert hash are logged to `control-plane/kubeadm-init.log`, keep it secure.

kubelets run with `serverTLSBootstrap: true`, so their serving certs are issued
through CSRs. kubelet-csr-approver watches and approves them, which is what lets
metrics-server scrape kubelets. check it caught up:

```sh
kubectl get csr
kubectl top nodes    # needs a few seconds for the first metrics
```

a CSR for a node outside `providerRegex` is left Pending rather than Denied
(`skipDenyStep`), so approve it by hand if needed:

```sh
kubectl certificate approve <csr-name>
```

### 5. Join worker nodes

for each worker, edit `worker/kubeadm-join.yaml`:

```yaml
nodeRegistration:
  name: instance-3          # <- actual node name
  kubeletExtraArgs:
    - name: "node-ip"
      value: "10.9.8.3"     # <- actual node IP
discovery:
  bootstrapToken:
    apiServerEndpoint: 10.9.8.2:6443
    token: "xxxx.yyyyyyy"                    # <- from kubeadm-init.log
    caCertHashes:
     - "sha256:zzzzzzzzzzzzzzzzzzzzzzzz..."  # <- from kubeadm-init.log
```

copy the edited file to the worker, then:

```sh
worker/join.sh
```

this starts containerd + kubelet and runs `kubeadm join`.

### 6. Post-join: nodeipam

on the control-plane, after the workers joined:

```sh
control-plane/exclude-lb.sh instance-2 instance-3
control-plane/untaint-lb-worker.sh instance-4
```

`exclude-lb.sh` labels the nodes that are not externally reachable, so cilium
nodeipam only advertises instance-4's IP for LoadBalancer services.

`untaint-lb-worker.sh` removes the `node.cloudprovider.kubernetes.io/uninitialized`
taint from instance-4. instance-4 joins with kubelet `cloud-provider=external`
(uncomment it in `worker/kubeadm-join.yaml`), but no real CCM runs, so nothing
clears the taint.

## Reset

when init or join fails mid-way, or just want a clean slate.

destructive and one-way: this drops all cluster state, and is not recoverable.

### FYI

- don't enable containerd/kubelet yet. the scripts only `start` them; enable comes after everything works (see "Enable services"). a half-configured stack coming back after reboot is relatively hard to debug.
- cni conf and bin dirs are non-standard (`/usr/local/etc/cni/net.d`, `/usr/local/libexec/cni/bin`). a distro may ship podman/docker plugins at the standard `/etc/cni/net.d` + `/opt/cni/bin` which are not what this setup uses.
- `rm -rf /etc/kubernetes` takes the encryption key (`/etc/kubernetes/enc/enc.yaml`) with it. `gen-enc.sh` mints a new one on the next init, so anything encrypted with the old key becomes undecryptable. copy the key out first if you want to keep it.

### reset to clean state

```sh
systemctl disable kubelet containerd  # just to make sure
kubeadm reset -f    # errors are fine if the node never fully init'd
                    # wait. may get stuck, interrupt it by pressing ctrl-c
reboot
```

after reboot:

```sh
rm -rf /var/lib/{containerd,etcd,kubelet}
rm -rf /etc/kubernetes /etc/containerd/config.toml   # /etc/kubernetes also holds the encryption key
rm -rf /usr/local/etc/cni/net.d /usr/local/libexec/cni/bin/*
```

fix/adjust as needed, then re-run `control-plane/init.sh` or `worker/join.sh`.

## Testing / verifying the cluster

smoke tests, each a step closer to the real thing.

### 1. one-off pod

kubectl reaches the API server and a pod image pulls:

```sh
kubectl run --rm -it demo --restart=Never --image=busybox -- date
```

### 2. deployment + service

pods schedule, the Service groups them, networking resolves:

```sh
kubectl apply -f example/demo.yaml
kubectl get pods -l app=demo -w
```

hit the Service from your workstation once Ready:

```sh
kubectl port-forward svc/demo 8080:80 &
curl -s http://localhost:8080
kill %1
```

cleanup:

```sh
kubectl delete -f example/demo.yaml
```

### 3. gateway API / whoami

full path: ExternalIP -> Cilium LB -> Gateway -> HTTPRoute -> Service -> Pods. shows the cluster serving traffic from outside.

cilium runs with nodeipam (`defaultLBServiceIPAM: nodeipam` in
`control-plane/addons/cilium/values.yaml`): LoadBalancer services get node IPs,
and only instance-4 is externally reachable (the other nodes carry the
`node.kubernetes.io/exclude-from-external-load-balancers` label, see step 6).

```sh
kubectl apply -f example/nodeipam/gateway.yaml

kubectl -n kube-public get gateway common   # address = 10.9.8.4
```

the listener hostname is `203.0.113.10.nip.io` (203.0.113.0/24 is the TEST-NET-3
documentation range, replace it with yours), matching the public address the
VPS provider 1:1 NATs to instance-4's private address.

before this works from the workstation, the NSG needs 80/tcp inbound on instance-4's public address.
allow it from your own public address first, widen it to anywhere once the path is proven.
hit it from the workstation:

```sh
curl -v http://203.0.113.10.nip.io/
```

404. the gateway answers but no route matches yet.

```sh
kubectl apply -f example/whoami.yaml
kubectl -n whoami wait --for=condition=Available deploy/hello --timeout=30s
curl http://203.0.113.10.nip.io/
```

now it returns the whoami response (hostname, client IP, request headers).

cleanup:

```sh
kubectl delete -f example/nodeipam/gateway.yaml -f example/whoami.yaml
```

## Enable services

once everything went well, enable containerd and kubelet so they survive a reboot:

```sh
systemctl enable containerd kubelet
```

on the control-plane plus every worker.

## References

upstream docs this was built from: [ref.txt](ref.txt)

