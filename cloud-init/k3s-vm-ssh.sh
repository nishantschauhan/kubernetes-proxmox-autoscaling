
set -euo pipefail

date +%s%3N > /var/log/thesis-t-boot-start
echo "[thesis] Starting K3s-on-VM bootstrap"

swapoff -a || true
sed -i '/ swap / s/^/#/' /etc/fstab || true

curl -sfL https://get.k3s.io | \
  K3S_URL="https://${control_plane_endpoint}" \
  K3S_TOKEN="${k3s_token}" \
  INSTALL_K3S_VERSION="${k3s_version}" \
  sh -s - 2>&1 | tee -a /var/log/thesis-bootstrap.log

date +%s%3N > /var/log/thesis-t-joined
echo "[thesis] K3s-on-VM bootstrap complete"
