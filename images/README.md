# images

optional. preload container images and helm charts on the nodes so `kubeadm init`
and `kubeadm join` skip internet pulls. images not preloaded still pull from their
registry as usual, charts not downloaded still pull from their repository.

if you run a private, offline, or caching registry the nodes can reach, skip this overlay

two examples, repeat the save/load pair for every other image. "which images a
chart deploys" lists them per chart.

## prerequisites

- `skopeo` on the saving machine. not needed on the nodes.
- `helm` on the saving machine, for the chart pulls.
- `ctr` on the nodes. ships with containerd (step 2).
- archive arch must match node arch. examples use `arm64`, matching
  `download/download.sh`; use `amd64` if changed there.

## which images a chart deploys

render the chart and read its image lines, from the repo root.

```sh
helm template cilium oci://quay.io/cilium/charts/cilium --version 1.20.4 \
  -n kube-system --values control-plane/addons/cilium/values.yaml \
  | awk '$1 == "image:" {print $2}' | tr -d '"' | sort -u
```

at these pins it prints:

```txt
quay.io/cilium/cilium-envoy:v1.39.5-1792733054-8c73b2816bc8239e27f1fd53b271884688137459@sha256:547ab45f6092f681d9f54f3be9fa8fb1e705c9c5dc2df388efe3a52aa6965629
quay.io/cilium/cilium:v1.20.4@sha256:20fe92e4c86641233a450098c158d2d29085f3419931ab6bf681d2485dedf16e
quay.io/cilium/operator-generic:v1.20.4@sha256:7a7a3489dc66ad67e420d285c8a8d2e169b0957ad15e120f593d27081bf38d82
```

`--version` and `--values` must be the ones `control-plane/addons/cilium/install.sh`
deploys with. a different chart or values renders a different set of pods, and the
archives then match nothing that runs.

render the released chart, not a git checkout of the same tag. the source tree at
`v1.20.4` has `image.digest: ""` and `image.useDigest: false`, so it renders
`quay.io/cilium/cilium:v1.20.4` with no digest. the released tarball bakes both in,
which is what `cilium install` deploys.

re-run after a version bump or a values change. hubble, spire and ztunnel images
only appear with those features enabled.

the other two addon charts are tag-referenced:

```sh
helm template metrics-server metrics-server \
  --repo https://kubernetes-sigs.github.io/metrics-server/ --version 3.14.0 \
  -n kube-system | awk '$1 == "image:" {print $2}' | tr -d '"' | sort -u
# registry.k8s.io/metrics-server/metrics-server:v0.9.0

helm template kubelet-csr-approver kubelet-csr-approver \
  --repo https://postfinance.github.io/kubelet-csr-approver --version 1.2.13 \
  -n kube-system | awk '$1 == "image:" {print $2}' | tr -d '"' | sort -u
# ghcr.io/postfinance/kubelet-csr-approver:v1.2.13
# plus an untagged busybox for the chart's helm test hook, not pulled by the install
```

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

the released cilium chart pins every image it deploys by digest: `cilium` (agent),
`operator-generic` (operator) and `cilium-envoy` at these values. `useDigest: true`
with a `digest:` baked into the released chart. which extra images pull depends on
the enabled features.

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

all three cilium refs come out as `repository:tag@sha256:<digest>`, so a
`docker-archive` import named `repository:tag` leaves the digest reference
unresolved: no entry matches the name CRI asks for, and the pods stay in
`ImagePullBackOff` on a node without registry access. import the archive, then add
the digest name.

save on the machine with internet access:

```sh
ref=quay.io/cilium/cilium-envoy
tag=v1.39.5-1792733054-8c73b2816bc8239e27f1fd53b271884688137459

skopeo copy --override-os linux --override-arch arm64 \
  "docker://$ref:$tag" \
  "oci-archive:images/dist/cilium-envoy.oci.tar:$ref:$tag"
```

the reference after the archive name is ignored by the import below: `--base-name`
sets the entry name to the repository, the tag step adds the digest name.

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

the digest reference must be listed. a missing one leaves the pods in
`ImagePullBackOff` on a node that cannot reach the registry.

on the machine with internet access, split the render into the three values each
save and load needs:

```sh
mkdir -p images/dist

helm template cilium oci://quay.io/cilium/charts/cilium --version 1.20.4 \
  -n kube-system --values control-plane/addons/cilium/values.yaml \
  | awk '$1 == "image:" {print $2}' | tr -d '"' | sort -u > images/dist/cilium-refs.txt

while IFS= read -r ref; do
  base=${ref%@*}
  printf 'ref=%s\ntag=%s\ndigest=%s\n\n' "${base%:*}" "${base##*:}" "${ref##*@}"
done < images/dist/cilium-refs.txt
```

`ref` is the repository, `tag` the part before `@`, `digest` the part after. run
save and load for each line.

when bumping cilium, take all three from the same block in the chart values
(`image`, `operator.image`, `envoy.image`). they move together, or the digest
reference stops matching the podspec.

setting `envoy.image.useDigest: false` in
`control-plane/addons/cilium/values.yaml` drops the digest pin; a docker-archive
of the tag then works through the generic pair. the agent and operator carry the
same switch, `image.useDigest` and `operator.image.useDigest`. the values file with
them off has to be the one `cilium install` runs with, or the podspec still asks
for a digest.

## repeating

`kubeadm config images list --kubernetes-version v1.37.1` prints the
control-plane set (minus kube-proxy, skipped here). the addons pull their own;
enumerate those with the render command under "which images a chart deploys".

workers need `pause` for the sandbox plus what the cilium agent pod runs: `cilium`
and `cilium-envoy`. `operator-generic` only has to exist where the operator
schedules.

`ctr -n k8s.io i ls` on an initialized node shows what actually landed,
including the digest-pinned cilium entries (`repository@sha256:` names) and any
example or test images deployed. filter to name:tag references:

```sh
ctr -n k8s.io i ls -q | grep -v '@sha256:'
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

preload the sonobuoy images (listed in [sonobuoy-images.txt](sonobuoy-images.txt))
on the nodes using the save/load steps above, then run conformance:

```sh
sonobuoy run --mode=certified-conformance --force-image-pull-policy --image-pull-policy IfNotPresent
```

