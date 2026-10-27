
set -euo pipefail

echo "[thesis] Starting kubeadm control-plane bootstrap (VM)"

swapoff -a || true
sed -i '/ swap / s/^/#/' /etc/fstab || true


modprobe overlay
modprobe br_netfilter
cat > /etc/modules-load.d/k8s.conf << 'MOD'
overlay
br_netfilter
MOD

# kubeadm preflight requires ip_forward=1 (not on by default).
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

echo "[1/4] Installing containerd..."
apt_retry apt-get update -qq
apt_retry apt-get install -y -qq apt-transport-https ca-certificates curl gpg containerd conntrack

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd && systemctl enable containerd

echo "[2/4] Installing kubeadm/kubelet/kubectl..."
mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${k8s_minor_version}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${k8s_minor_version}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt_retry apt-get update -qq
apt_retry apt-get install -y -qq kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl >/dev/null

echo "[3/4] Initialising cluster..."
kubeadm init \
  --apiserver-advertise-address="${ip_address}" \
  --pod-network-cidr="${pod_cidr}"

export KUBECONFIG=/etc/kubernetes/admin.conf
mkdir -p "$HOME/.kube"
cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"

echo "[4/4] Installing Flannel CNI..."
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

echo "[thesis] Waiting for control-plane node to be Ready..."
until kubectl get node --no-headers 2>/dev/null | grep -q " Ready "; do
  sleep 3
done

TOKEN=$(kubeadm token create)
CA_HASH=$(openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt \
          | openssl rsa -pubin -outform der 2>/dev/null \
          | openssl dgst -sha256 -hex | sed 's/^.* //')

{
  echo "$TOKEN"
  echo "$CA_HASH"
} > /tmp/join-info

# ephemeral lab node.
chmod 644 /tmp/join-info

echo "[thesis] kubeadm control-plane bootstrap complete"
