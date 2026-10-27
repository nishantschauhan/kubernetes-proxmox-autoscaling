
set -euo pipefail

echo "[thesis] Starting K3s control-plane bootstrap"

if [ ! -e /dev/kmsg ]; then
  ln -s /dev/console /dev/kmsg
fi

swapoff -a || true
apt-get update
apt-get install -y curl

curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="${k3s_version}" \
  K3S_NODE_NAME="k3s-control" \
  sh -s - server \
    --node-ip "${ip_address}" \
    --advertise-address "${ip_address}" \
    --cluster-cidr "${cluster_cidr}" \
    --disable traefik \
    --disable servicelb \
    --kubelet-arg="feature-gates=KubeletInUserNamespace=true" \
    --snapshotter=native

echo "[thesis] Waiting for control-plane node to be Ready..."
until k3s kubectl get node --no-headers 2>/dev/null | grep -q " Ready "; do
  sleep 3
done

cp /var/lib/rancher/k3s/server/node-token /root/node-token
chmod 600 /root/node-token

echo "[thesis] K3s control-plane bootstrap complete; node-token written to /root/node-token"
