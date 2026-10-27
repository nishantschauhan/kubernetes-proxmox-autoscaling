
set -euo pipefail

# --- Timestamp: bootstrap begins ------------------------------------------
date +%s%3N > /var/log/thesis-t-boot-start

echo "[thesis] Starting kubeadm-on-LXC bootstrap"

e.
if [ ! -e /dev/kmsg ]; then
  ln -s /dev/console /dev/kmsg
fi

cat > /etc/systemd/system/kmsg-link.service << 'UNIT'
[Unit]
Description=Link /dev/kmsg for kubelet in LXC
Before=kubelet.service
[Service]
Type=oneshot
ExecStart=/bin/sh -c '[ -e /dev/kmsg ] || ln -s /dev/console /dev/kmsg'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT
systemctl enable kmsg-link.service


for mod in overlay br_netfilter; do
  if ! grep -q "^$${mod}" /proc/modules 2>/dev/null; then
    echo "[thesis] WARNING: $${mod} not loaded on the Proxmox host."
    echo "[thesis] Run on the HOST: modprobe $${mod}"
  fi
done

# --- Common Kubernetes prerequisites --------------------------------------
swapoff -a || true
sed -i '/ swap / s/^/#/' /etc/fstab || true


sysctl -w net.ipv4.ip_forward=1
cat > /etc/sysctl.d/99-kubernetes-cri.conf << 'SYSCTL'
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
SYSCTL
sysctl --system >/dev/null

apt-get update
apt-get install -y apt-transport-https ca-certificates curl gpg containerd conntrack

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

sed -i 's/disable_apparmor = false/disable_apparmor = true/' /etc/containerd/config.toml
sed -i 's/restrict_oom_score_adj = false/restrict_oom_score_adj = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${k8s_minor_version}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${k8s_minor_version}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl



echo 'KUBELET_EXTRA_ARGS=--fail-swap-on=false --cgroup-driver=systemd --feature-gates=KubeletInUserNamespace=true' \
  > /etc/default/kubelet
systemctl daemon-reload


kubeadm join "${control_plane_endpoint}" \
  --token "${kubeadm_token}" \
  --discovery-token-ca-cert-hash "sha256:${kubeadm_ca_hash}" \
  --ignore-preflight-errors=SystemVerification,FileContent--proc-sys-net-bridge-bridge-nf-call-iptables \
  --v=5 2>&1 | tee -a /var/log/thesis-bootstrap.log

date +%s%3N > /var/log/thesis-t-joined
echo "[thesis] kubeadm-on-LXC bootstrap complete"
