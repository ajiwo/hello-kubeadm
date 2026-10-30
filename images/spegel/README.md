# spegel

optional. a cluster-local OCI registry mirror (peer to peer): once one node has
an image, the others pull it from that node instead of the upstream registry.
useful on this cluster for the conformance run: some tests hardcode
`imagePullPolicy: Always`, and the rest pull whatever image their node lacks, so
without a mirror those pulls go to the internet. on an offline cluster the two
`Always` tests fail even with every image preloaded.

spegel is a DaemonSet installed with Helm, and needs at least two nodes `Ready`
before it can be installed (it is a peer-to-peer mirror). install it after the
workers joined.

## prerequisites

- containerd configured for mirroring on every node that should participate.
  the drop-in lives in this directory:

  ```sh
  # on each node, during step 3 (after copying etc/), before init/join:
  cp images/spegel/spegel.toml /etc/containerd/conf.d/spegel.toml
  ```

  containerd reads this at startup. if it is already running, restart it after
  installing the drop-in (`systemctl restart containerd`), otherwise the mirror
  config is written but never read.

  `config_path` points containerd at the mirror config spegel writes;
  `discard_unpacked_layers = false` keeps the layers it serves. without this
  drop-in spegel still starts and writes the config, but containerd never reads
  it and every pull goes straight to the registry: a silent no-op, not a startup
  error.

- the spegel image and chart available. preload the image (digest-pinned, like
  cilium) and pull the chart tarball:

  ```sh
  ref=ghcr.io/spegel-org/spegel
  tag=v0.8.1
  digest=sha256:bdc1d14e4ab76e9a74520d331f485d09a596110118bd1a7706fa0411f17b3703

  # on a machine with internet access:
  skopeo copy --override-os linux --override-arch arm64 \
    "docker://$ref:$tag" \
    "oci-archive:images/dist/spegel.oci.tar:$ref:$tag"

  # on each node, as root, before init/join:
  systemctl start containerd
  ctr -n k8s.io images import --platform linux/arm64 \
    --base-name "$ref" images/dist/spegel.oci.tar
  ctr -n k8s.io images tag --local --force "$ref:$tag" "$ref@$digest"
  ```

  the tag command adds the digest reference CRI resolves; without it the pods
  stay in `ImagePullBackOff`.

  ```sh
  # on the machine with internet access, in download/:
  helm pull oci://ghcr.io/spegel-org/helm-charts/spegel --version 0.8.1 --destination charts
  ```

## install

after the workers joined and at least two nodes are `Ready`:

```sh
cd images/spegel
./install.sh
```

`install.sh` installs from `../../download/charts/spegel-0.8.1.tgz` with
`spegel-values.yaml`. values are all defaults; `mirroredRegistries` is left
empty so every registry is mirrored.

## verify

spegel has no obvious success signal: if it cannot serve an image the pull
falls back to the upstream registry, so a broken install is silent. trigger a
pull on a second node and check the debug page:

```sh
kubectl --namespace spegel get pods -l app.kubernetes.io/name=spegel -o wide
# pick a spegel pod on a node different from the one that already has the image

kubectl --namespace spegel port-forward <spegel-pod-on-second-node> 9090
# open http://localhost:9090/debug/web
```

`Last Mirror Success` showing a duration means it worked. `Pending` means the
pull never went through spegel, ie. the containerd config is wrong.

the debug page loads htmx from unpkg.com, so the stats box needs internet on the
browser. without it, read the same value from the metrics endpoint:

```sh
curl -s localhost:9090/metrics | grep spegel_mirror_last_success_timestamp_seconds
```

## notes

- the mirror listens on `nodePort: 30020` on every node, unauthenticated. it is
  written into each node's containerd config as `http://<node-ip>:30020`, so the
  node itself is the only source that needs it. allow 30020 only from the node
  addresses and any host you intend to pull from the mirror, in the NSG and host
  firewall; a wider source range lets anyone pull anything in that node's
  content store. if a wider audience is intended, set `basicAuthSecretName` in
  the values.
- `containerdMirrorAdd: true` (default) makes spegel write the mirror config
  into `/etc/containerd/certs.d` itself. `prependExisting` is false, so it
  replaces rather than appends.
- tolerations in the chart cover `NoSchedule`/`NoExecute`, so spegel runs on
  the tainted control-plane too.
- version pinned: spegel 0.8.1, image
  `ghcr.io/spegel-org/spegel@sha256:bdc1d14e4ab76e9a74520d331f485d09a596110118bd1a7706fa0411f17b3703`.

