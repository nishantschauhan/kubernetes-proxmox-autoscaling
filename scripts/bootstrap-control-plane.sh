
set -euo pipefail

DISTRO="${1:?usage: bootstrap-control-plane.sh <kubeadm|k3s> <advertise-ip>}"
ADVERTISE_IP="${2:?usage: bootstrap-control-plane.sh <kubeadm|k3s> <advertise-ip>}"
K8S_MINOR="${K8S_MINOR:-v1.31}"
K3S_VERSION="${K3S_VERSION:-v1.31.4+k3s1}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"

echo "==========================================================="
echo " Bootstrapping ${DISTRO} control plane on ${ADVERTISE_IP}"
echo "==========================================================="

# --- Common prerequisites --------------------------------------------------
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

modprobe overlay || true
modprobe br_netfilter || true
cat > /etc/modules-load.d/k8s.conf << 'MOD'
overlay
br_netfilter
MOD

cat > /etc/sysctl.d/99-kubernetes.conf << 'SYS'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
SYS
sysctl --system >/dev/null

if [ "$DISTRO" = "kubeadm" ]; then
  # =========================================================================
  # kubeadm control plane
  # =========================================================================
  echo "[1/4] Installing containerd..."
  apt-get update -qq
  apt-get install -y -qq apt-transport-https ca-certificates curl gpg containerd

  mkdir -p /etc/containerd
  containerd config default > /etc/containerd/config.toml
  # kubelet and containerd must agree on the cgroup driver or kubelet fails
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  systemctl restart containerd && systemctl enable containerd

  echo "[2/4] Installing kubeadm/kubelet/kubectl..."
  mkdir -p /etc/apt/keyrings
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list
  apt-get update -qq
  apt-get install -y -qq kubelet kubeadm kubectl
  apt-mark hold kubelet kubeadm kubectl >/dev/null

  echo "[3/4] Initialising cluster..."
  kubeadm init \
    --apiserver-advertise-address="${ADVERTISE_IP}" \
    --pod-network-cidr="${POD_CIDR}" \
    --ignore-preflight-errors=NumCPU

  export KUBECONFIG=/etc/kubernetes/admin.conf
  mkdir -p "$HOME/.kube"
  cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"

  echo "[4/4] Installing Flannel CNI..."
  # A CNI is mandatory — without one, nodes stay NotReady forever.
  kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

  # --- Emit the values needed by production.tfvars -----------------------
  TOKEN=$(kubeadm token create)
  CA_HASH=$(openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt \
            | openssl rsa -pubin -outform der 2>/dev/null \
            | openssl dgst -sha256 -hex | sed 's/^.* //')

  echo ""
  echo "==========================================================="
  echo " PASTE THESE INTO opentofu/production.tfvars"
  echo "==========================================================="
  echo "k8s_control_plane_endpoint = \"${ADVERTISE_IP}:6443\""
  echo "kubeadm_join_token         = \"${TOKEN}\""
  echo "kubeadm_ca_cert_hash       = \"${CA_HASH}\""
  echo "k8s_minor_version          = \"${K8S_MINOR}\""
  echo "==========================================================="
  echo ""
  echo "NOTE: kubeadm tokens expire after 24h. Regenerate with:"
  echo "  kubeadm token create --print-join-command"

elif [ "$DISTRO" = "k3s" ]; then
  # =========================================================================
  # K3s control plane — one command, no separate CNI needed
  # =========================================================================
  echo "[1/2] Installing K3s server..."
  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_VERSION="${K3S_VERSION}" \
    K3S_NODE_NAME="k3s-control" \
    sh -s - server \
      --node-ip "${ADVERTISE_IP}" \
      --advertise-address "${ADVERTISE_IP}" \
      --cluster-cidr "${POD_CIDR}" \
      --disable traefik \
      --disable servicelb   # MUST disable: it conflicts with MetalLB

  echo "[2/2] Waiting for node to be Ready..."
  until k3s kubectl get node --no-headers 2>/dev/null | grep -q " Ready "; do
    sleep 3
  done

  NODE_TOKEN=$(cat /var/lib/rancher/k3s/server/node-token)

  echo ""
  echo "==========================================================="
  echo " PASTE THESE INTO opentofu/production.tfvars"
  echo "==========================================================="
  echo "k8s_control_plane_endpoint = \"${ADVERTISE_IP}:6443\""
  echo "k3s_token                  = \"${NODE_TOKEN}\""
  echo "k3s_version                = \"${K3S_VERSION}\""
  echo "==========================================================="
  echo ""
  echo "kubeconfig is at /etc/rancher/k3s/k3s.yaml"
  echo "Copy it to your laptop and replace 127.0.0.1 with ${ADVERTISE_IP}"

else
  echo "ERROR: distro must be 'kubeadm' or 'k3s'"
  exit 1
fi

echo ""
echo "Verify with:  kubectl get nodes -o wide"
