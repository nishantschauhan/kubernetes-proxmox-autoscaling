
set -euo pipefail

date +%s%3N > /var/log/thesis-t-boot-start
echo "[thesis] Starting kubeadm-on-VM bootstrap"

swapoff -a || true
sed -i '/ swap / s/^/#/' /etc/fstab || true


modprobe overlay
modprobe br_netfilter
cat > /etc/modules-load.d/k8s.conf << 'MOD'
overlay
br_netfilter
MOD


sysctl -w net.ipv4.ip_forward=1
cat > /etc/sysctl.d/99-kubernetes-cri.conf << 'SYSCTL'
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
SYSCTL
sysctl --system >/dev/null


apt_retry() {
  for i in $(seq 1 30); do
    if "$@"; then return 0; fi
    sleep 2
  done
  return 1
}

apt_retry apt-get update
apt_retry apt-get install -y apt-transport-https ca-certificates curl gpg containerd conntrack

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${k8s_minor_version}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${k8s_minor_version}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt_retry apt-get update
apt_retry apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

kubeadm join "${control_plane_endpoint}" \
  --token "${kubeadm_token}" \
  --discovery-token-ca-cert-hash "sha256:${kubeadm_ca_hash}" \
  --v=5 2>&1 | tee -a /var/log/thesis-bootstrap.log

date +%s%3N > /var/log/thesis-t-joined
echo "[thesis] kubeadm-on-VM bootstrap complete"
