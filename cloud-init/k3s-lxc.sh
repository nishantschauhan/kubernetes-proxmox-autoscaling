
set -euo pipefail

date +%s%3N > /var/log/thesis-t-boot-start
echo "[thesis] Starting K3s-on-LXC bootstrap"

# --- LXC-specific preparation ---------------------------------------------
if [ ! -e /dev/kmsg ]; then
  ln -s /dev/console /dev/kmsg
fi
cat > /etc/systemd/system/kmsg-link.service << 'UNIT'
[Unit]
Description=Link /dev/kmsg for kubelet in LXC
Before=k3s-agent.service
[Service]
Type=oneshot
ExecStart=/bin/sh -c '[ -e /dev/kmsg ] || ln -s /dev/console /dev/kmsg'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT
systemctl enable kmsg-link.service

swapoff -a || true
apt-get update
apt-get install -y curl


curl -sfL https://get.k3s.io | \
  K3S_URL="https://${control_plane_endpoint}" \
  K3S_TOKEN="${k3s_token}" \
  INSTALL_K3S_VERSION="${k3s_version}" \
  INSTALL_K3S_EXEC="agent --snapshotter=native --kubelet-arg=feature-gates=KubeletInUserNamespace=true" \
  sh -s - 2>&1 | tee -a /var/log/thesis-bootstrap.log

date +%s%3N > /var/log/thesis-t-joined
echo "[thesis] K3s-on-LXC bootstrap complete"
