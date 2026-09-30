#!/bin/sh
set -e

# change to amd64 for x86_64 nodes
ARCH="arm64"

# version pins
CONTAINERD_TAG="v2.3.4"
CRI_TOOLS_TAG="v1.36.0"
K8S_TAG="v1.37.0"
SCRIPT_TAG="v0.16.2"
CILIUM_TAG="v0.20.1"
HELM_TAG="v4.2.3"
RUNC_TAG="v1.4.3"

cd "$(dirname "$0")"

mkdir -p tmp && cd tmp

: "${DESTDIR:=../dist/usr/local}"
: "${DIST:=../dist}"
mkdir -p "${DESTDIR}/bin" "${DESTDIR}/libexec/cni/bin"

# containerd
curl -sSLO "https://github.com/containerd/containerd/releases/download/${CONTAINERD_TAG}/containerd-${CONTAINERD_TAG#v}-linux-${ARCH}.tar.gz"
curl -sSLO "https://github.com/containerd/containerd/releases/download/${CONTAINERD_TAG}/containerd-${CONTAINERD_TAG#v}-linux-${ARCH}.tar.gz.sha256sum"
sha256sum -c "containerd-${CONTAINERD_TAG#v}-linux-${ARCH}.tar.gz.sha256sum"
tar -C "${DESTDIR}" -xzf "containerd-${CONTAINERD_TAG#v}-linux-${ARCH}.tar.gz"
curl -sSLO https://github.com/containerd/containerd/raw/refs/heads/main/containerd.service

# cni-plugins: not needed. cilium ships its own cilium-cni + loopback
# in its image and installs them via the install-cni-binaries init
# container into ${DESTDIR}/libexec/cni/bin at deploy time. keep the
# dir so the layout and containerd bin_dirs reference stay valid.
#CNI_PLUGINS_TAG="v1.9.1"
#curl -sSLO "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_TAG}/cni-plugins-linux-${ARCH}-${CNI_PLUGINS_TAG}.tgz"
#curl -sSLO "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_TAG}/cni-plugins-linux-${ARCH}-${CNI_PLUGINS_TAG}.tgz.sha256"
#sha256sum -c "cni-plugins-linux-${ARCH}-${CNI_PLUGINS_TAG}.tgz.sha256"
#tar -C "${DESTDIR}/libexec/cni/bin" -xzf "cni-plugins-linux-${ARCH}-${CNI_PLUGINS_TAG}.tgz"

# etcd: not needed. kubeadm runs etcd as a static pod from
# registry.k8s.io/etcd:3.7.0-0 (kubeadm's DefaultEtcdVersion for k8s
# 1.37), and etcdctl is already inside that image, so
#   kubectl -n kube-system exec etcd-instance-2 -- etcdctl ...
# covers testing/debugging. uncomment to get host-side etcd/etcdctl/
# etcdutl in ${DESTDIR}/bin, e.g. to poke at /var/lib/etcd offline.
#ETCD_TAG="v3.7.0"
#curl -sSLO "https://github.com/etcd-io/etcd/releases/download/${ETCD_TAG}/etcd-${ETCD_TAG}-linux-${ARCH}.tar.gz"
#curl -sSLO "https://github.com/etcd-io/etcd/releases/download/${ETCD_TAG}/SHA256SUMS"
#ETCDSUM=$(mktemp)
#grep "etcd-${ETCD_TAG}-linux-${ARCH}.tar.gz\$" SHA256SUMS > "$ETCDSUM"
#sha256sum -c "$ETCDSUM"
#rm -f "$ETCDSUM"
#tar -C "${DESTDIR}/bin" --strip-components=1 -xzf "etcd-${ETCD_TAG}-linux-${ARCH}.tar.gz" \
#     "etcd-${ETCD_TAG}-linux-${ARCH}/etcd" \
#     "etcd-${ETCD_TAG}-linux-${ARCH}/etcdctl" \
#     "etcd-${ETCD_TAG}-linux-${ARCH}/etcdutl"
#chmod 755 "${DESTDIR}/bin/etcd" "${DESTDIR}/bin/etcdctl" "${DESTDIR}/bin/etcdutl"

# crictl
curl -sSLO "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRI_TOOLS_TAG}/crictl-${CRI_TOOLS_TAG}-linux-${ARCH}.tar.gz"
curl -sSLO "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRI_TOOLS_TAG}/crictl-${CRI_TOOLS_TAG}-linux-${ARCH}.tar.gz.sha256"
CRICTLSUM=$(mktemp)
echo "$(cat "crictl-${CRI_TOOLS_TAG}-linux-${ARCH}.tar.gz.sha256")  crictl-${CRI_TOOLS_TAG}-linux-${ARCH}.tar.gz" > "$CRICTLSUM"
sha256sum -c "$CRICTLSUM"
rm -f "$CRICTLSUM"
tar -C "${DESTDIR}/bin" -xzf "crictl-${CRI_TOOLS_TAG}-linux-${ARCH}.tar.gz"

# k8s binaries (kubeadm, kubelet, kubectl)
curl -sSL --remote-name-all "https://dl.k8s.io/release/${K8S_TAG}/bin/linux/${ARCH}/{kubeadm,kubelet,kubectl}"
for bin in kubeadm kubelet kubectl; do
  curl -sSL --remote-name "https://dl.k8s.io/release/${K8S_TAG}/bin/linux/${ARCH}/${bin}.sha256"
  KUBESUM=$(mktemp)
  echo "$(cat "${bin}.sha256")  ${bin}" > "$KUBESUM"
  sha256sum -c "$KUBESUM"
  install -m 755 "${bin}" "${DESTDIR}/bin/${bin}"
  rm -f "$KUBESUM"
done

# cilium cli
curl -sSLO "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_TAG}/cilium-linux-${ARCH}.tar.gz"
curl -sSLO "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_TAG}/cilium-linux-${ARCH}.tar.gz.sha256sum"
sha256sum -c "cilium-linux-${ARCH}.tar.gz.sha256sum"
tar -C "${DESTDIR}/bin" -xzf "cilium-linux-${ARCH}.tar.gz"

# helm
curl -sSLO "https://get.helm.sh/helm-${HELM_TAG}-linux-${ARCH}.tar.gz"
curl -sSLO "https://get.helm.sh/helm-${HELM_TAG}-linux-${ARCH}.tar.gz.sha256"
HELMVAL=$(mktemp)
echo "$(cat "helm-${HELM_TAG}-linux-${ARCH}.tar.gz.sha256")  helm-${HELM_TAG}-linux-${ARCH}.tar.gz" > "$HELMVAL"
sha256sum -c "$HELMVAL"
rm -f "$HELMVAL"
tar -C "${DESTDIR}/bin" --strip-components=1 -xzf "helm-${HELM_TAG}-linux-${ARCH}.tar.gz" "linux-${ARCH}/helm"

# runc
curl -sSLO "https://github.com/opencontainers/runc/raw/refs/tags/${RUNC_TAG}/runc.keyring"
curl -sSLO "https://github.com/opencontainers/runc/releases/download/${RUNC_TAG}/runc.${ARCH}.asc"
curl -sSLO "https://github.com/opencontainers/runc/releases/download/${RUNC_TAG}/runc.${ARCH}"
tmpgpg="$(mktemp -d)"
gpg --home $tmpgpg --import runc.keyring
gpg --home $tmpgpg --verify "runc.${ARCH}.asc" "runc.${ARCH}"
install -m 755 "runc.${ARCH}" "${DESTDIR}/bin/runc"
rm -rf $tmpgpg

# systemd service files
curl -sSLO "https://raw.githubusercontent.com/kubernetes/release/${SCRIPT_TAG}/cmd/krel/templates/latest/kubelet/kubelet.service"
curl -sSLO "https://raw.githubusercontent.com/kubernetes/release/${SCRIPT_TAG}/cmd/krel/templates/latest/kubeadm/10-kubeadm.conf"

SD="${DIST}/etc/systemd/system"
mkdir -p "${SD}/kubelet.service.d"

# containerd's unit already runs /usr/local/bin/containerd, only PATH needs patching
sed -e '/^\[Service\]/a Environment="PATH=/usr/local/bin:/usr/bin:/usr/sbin"' \
  containerd.service \
  > "${SD}/containerd.service"

{
  echo "# /etc/systemd/system/kubelet.service"
  sed -e '/^\[Service\]/a Environment="PATH=/usr/local/bin:/usr/bin:/usr/sbin"' \
      -e 's|/usr/bin/kubelet|/usr/local/bin/kubelet|g' kubelet.service
} > "${SD}/kubelet.service"

{
  echo "# /etc/systemd/system/kubelet.service.d/10-kubeadm.conf"
  sed 's|/usr/bin/kubelet|/usr/local/bin/kubelet|g' 10-kubeadm.conf
} > "${SD}/kubelet.service.d/10-kubeadm.conf"

chmod 644 "${SD}/containerd.service" "${SD}/kubelet.service" \
          "${SD}/kubelet.service.d/10-kubeadm.conf"

