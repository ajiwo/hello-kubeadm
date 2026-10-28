# images

optional. preload container images and helm charts on the nodes so `kubeadm init`
and `kubeadm join` skip internet pulls. images not preloaded still pull from their
registry as usual, charts not downloaded still pull from their repository.

if you run a private, offline, or caching registry the nodes can reach, skip this overlay

two examples, repeat the save/load pair for every other image.

## prerequisites

- `skopeo` on the saving machine. not needed on the nodes.
- `helm` on the saving machine, for the chart pulls.
- `ctr` on the nodes. ships with containerd (step 2).
- archive arch must match node arch. examples use `arm64`, matching
  `download/download.sh`; use `amd64` if changed there.

## save

on a machine with internet access:

```sh
skopeo copy --override-os linux --override-arch arm64 \
  docker://registry.k8s.io/kube-apiserver:v1.37.1 \
  docker-archive:images/dist/registry.k8s.io_kube-apiserver_v1.37.1.tar:registry.k8s.io/kube-apiserver:v1.37.1
```

value after the second colon = image name stored in the archive. keep identical
to the reference the cluster requests, or load creates an image nobody looks up.

## load

on the node, with root privileges, after step 3 and before `control-plane/init.sh` (step 4)
or `worker/join.sh` (step 5):

```sh
systemctl start containerd
ctr -n k8s.io images import --platform linux/arm64 \
  images/dist/registry.k8s.io_kube-apiserver_v1.37.1.tar
```

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
tag=v1.39.5-1792733054-8c73b2816bc8239e27f1fd53b271884688137459

skopeo copy --override-os linux --override-arch arm64 \
  "docker://$ref:$tag" \
  "oci-archive:images/dist/cilium-envoy.oci.tar:$ref:$tag"
```

the reference after the archive name is the image name stored in the archive.
import creates it as a tag.

on each node, as root, run from `/root/hello-kubeadm`:

```sh
ref=quay.io/cilium/cilium-envoy
tag=v1.39.5-1792733054-8c73b2816bc8239e27f1fd53b271884688137459
digest=sha256:547ab45f6092f681d9f54f3be9fa8fb1e705c9c5dc2df388efe3a52aa6965629

systemctl start containerd
ctr -n k8s.io images import --platform linux/arm64 \
  --base-name "$ref" images/dist/cilium-envoy.oci.tar

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

`ctr -n k8s.io i ls` on an initialized node shows what actually landed,
including digest-pinned cilium images (`sha256:` lines) and any example
or test images deployed. filter to name:tag references:

```sh
ctr -n k8s.io i ls -q | grep -v '^sha256:'
```

## helm charts

`init.sh` installs the kubelet-csr-approver and metrics-server addons with
helm, which fetches each chart from its repository. same offline story as the
images: download the charts on the machine with internet access, install from
the tarballs.

on a machine with internet access, in the `download/` directory:

```sh
# pwd
# /root/hello-kubeadm

cd download
rm -rf charts
mkdir -p charts

helm pull metrics-server --repo https://kubernetes-sigs.github.io/metrics-server/ \
  --version 3.14.0 --destination charts
helm pull kubelet-csr-approver --repo https://postfinance.github.io/kubelet-csr-approver \
  --version 1.2.13 --destination charts
helm pull oci://quay.io/cilium/charts/cilium --version 1.20.4 --destination charts
```

update the addon install scripts:

```sh
# control-plane/addons/csr-approver/install.sh
#!/bin/sh
set -e

helm --namespace kube-system upgrade \
  --install kubelet-csr-approver ../../../download/charts/kubelet-csr-approver-1.2.13.tgz \
  --values values.yaml \
  --wait
```

```sh
# control-plane/addons/metrics-server/install.sh
#!/bin/sh
set -e

helm --namespace kube-system upgrade \
  --install metrics-server ../../../download/charts/metrics-server-3.14.0.tgz \
  --values values.yaml \
  --wait
```

```sh
# control-plane/addons/cilium/install.sh
#!/bin/sh
set -e

# standard gateway-api v1.6.3 CRDs, cached locally
kubectl apply -f gateway-crds.yaml

helm --namespace kube-system upgrade \
  --install cilium ../../../download/charts/cilium-1.20.4.tgz \
  --values values.yaml \
  --wait
```

## conformance

run sonobuoy conformance against the image-preloaded cluster:

```sh
sonobuoy run --mode=certified-conformance --force-image-pull-policy --image-pull-policy IfNotPresent
```

`--force-image-pull-policy --image-pull-policy IfNotPresent` pulls sonobuoy images [sonobuoy-images.txt](sonobuoy-images.txt)
from the node's local containerd instead of a registry.

