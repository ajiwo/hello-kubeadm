# images

optional. preloads container images on the nodes so `kubeadm init` and `kubeadm
join` skip internet pulls. images not preloaded still pull from their registry
as usual.

two examples, repeat the save/load pair for every other image.

## prerequisites

- `skopeo` on the saving machine. not needed on the nodes.
- `ctr` on the nodes. ships with containerd (step 2).
- archive arch must match node arch. examples use `arm64`, matching
  `download/download.sh`; use `amd64` if changed there.

## save

on a machine with internet access:

```sh
skopeo copy --override-os linux --override-arch arm64 \
  docker://registry.k8s.io/kube-apiserver:v1.37.1 \
  docker-archive:registry.k8s.io_kube-apiserver_v1.37.1.tar:registry.k8s.io/kube-apiserver:v1.37.1
```

value after the second colon = image name stored in the archive. keep identical
to the reference the cluster requests, or load creates an image nobody looks up.

copy the `.tar` to the node, e.g. `/root/images/`. keep archives out of the repo.

## load

on the node, with root privileges, after step 3 and before `control-plane/init.sh` (step 4)
or `worker/join.sh` (step 5):

```sh
systemctl start containerd
ctr -n k8s.io images import --platform linux/arm64 \
  /root/images/registry.k8s.io_kube-apiserver_v1.37.1.tar
```

- `-n k8s.io` = namespace kubelet and kubeadm read. an image in any other
  namespace is invisible to them and pulls anyway.
- `init.sh` and `join.sh` start containerd themselves, so starting it here first
  is safe.

check it landed:

```sh
ctr -n k8s.io images ls -q | grep kube-apiserver
```

## digest-pinned images

several cilium images deploy by digest (`useDigest: true` in the chart):
cilium-envoy, ztunnel, certgen, hubble-ui, hubble-ui-backend, startup-script,
busybox, spire-agent, spire-server. which ones actually pull depends on the
enabled features. the default install here needs cilium-envoy; the pair below
works for any of them, substituting repository, tag and digest.

the digest is the upstream multi-arch index digest. an `--override-arch` copy
stores the single-platform manifest, so the archive's manifest digest is not the
index digest the chart references.

containerd resolves references by literal string. the CRI `LocalResolve`
function runs them through `ParseDockerRef`, which drops the tag from a tag+digest
reference, leaving `quay.io/cilium/cilium-envoy@sha256:d6c8...` as the lookup name
([normalize.go](https://github.com/containerd/containerd/blob/v2.3.6/vendor/github.com/distribution/reference/normalize.go#L107-L121),
[service.go](https://github.com/containerd/containerd/blob/v2.3.6/internal/cri/server/images/service.go#L158-L178)).
the node needs an image entry with that name. the name is a lookup key; the entry
points at the imported manifest, whose digest differs.

save on the machine with internet access:

```sh
ref=quay.io/cilium/cilium-envoy
tag=v1.38.6-1791537840-00e749f11f69334c625e53fc1ce2fc6c7f34a51f

skopeo copy --override-os linux --override-arch arm64 \
  "docker://$ref:$tag" \
  "oci-archive:cilium-envoy.oci.tar:$ref:$tag"
```

the reference after the archive name is the image name stored in the archive.
import creates it as a tag.

copy `cilium-envoy.oci.tar` to `/root/images/` on every node, then as root:

```sh
ref=quay.io/cilium/cilium-envoy
tag=v1.38.6-1791537840-00e749f11f69334c625e53fc1ce2fc6c7f34a51f
digest=sha256:d6c8c0c91954d1885026d82a31b341f37dcd34a4b127fdaf1587e43ddd224cef

systemctl start containerd
ctr -n k8s.io images import --platform linux/arm64 \
  --base-name "$ref" /root/images/cilium-envoy.oci.tar

ctr -n k8s.io images tag --local --force "$ref:$tag" "$ref@$digest"
# optional: drop the tag reference, only the digest entry is needed
ctr -n k8s.io images del "$ref:$tag"
```

the tag command adds the digest reference CRI resolves. run import and tag
before `kubeadm init` or `kubeadm join`. check:

```sh
ctr -n k8s.io images ls -q | grep cilium-envoy
```

the digest reference must be listed. a missing one leaves the envoy pods in
`ImagePullBackOff` on a node that cannot reach the registry.

when bumping cilium, take repository, tag and digest from the same
`envoy.image` block. all three move together, or the digest reference stops
matching the podspec.

the cilium agent and operator images are tag-referenced, so the generic pair
covers them.

setting `envoy.image.useDigest: false` in
`control-plane/addons/cilium/values.yaml` drops the digest pin; a docker-archive
of the tag then works through the generic pair

## repeating

`kubeadm config images list --kubernetes-version v1.37.1` prints the
control-plane set (minus kube-proxy, skipped here). addons add their own:
cilium, metrics-server, kubelet-csr-approver. workers need the images their pods
run, at least `pause` for the sandbox and the cilium agent.

