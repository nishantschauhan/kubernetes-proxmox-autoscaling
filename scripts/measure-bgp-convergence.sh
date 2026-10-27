
set -euo pipefail

SERVICE_IP="${1:?usage: measure-bgp-convergence.sh <service-ip> [timeout-s]}"
TIMEOUT_S="${2:-120}"
RESULTS_DIR="$(dirname "$0")/../results"
CSV="${RESULTS_DIR}/bgp-convergence.csv"

mkdir -p "$RESULTS_DIR"
[ -f "$CSV" ] || echo "run_timestamp,service_ip,t_start_ms,t_route_ms,convergence_ms,outcome" > "$CSV"

now_ms() { echo $(( $(date +%s%N) / 1000000 )); }

# Check whether FRRouting has the route. vtysh is FRR's shell.
route_present() {
  vtysh -c "show ip route ${SERVICE_IP}" 2>/dev/null | grep -q "via" && echo 1 || echo 0
}

T_START=$(now_ms)
echo "[bgp] watching for route to ${SERVICE_IP} (timeout ${TIMEOUT_S}s)"
echo "[bgp] T_start = ${T_START}"

DEADLINE=$(( $(date +%s) + TIMEOUT_S ))
T_ROUTE=""
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  if [ "$(route_present)" -eq 1 ]; then
    T_ROUTE=$(now_ms)
    break
  fi
  sleep 0.2
done

if [ -z "$T_ROUTE" ]; then
  echo "[bgp] TIMEOUT — route never appeared. Check the BGP session:"
  echo "      vtysh -c 'show bgp summary'"
  echo "$(date -Iseconds),${SERVICE_IP},${T_START},,,timeout" >> "$CSV"
  exit 1
fi

CONV_MS=$(( T_ROUTE - T_START ))
echo "======================================================"
echo "  BGP CONVERGENCE : ${CONV_MS} ms"
echo "======================================================"
echo "$(date -Iseconds),${SERVICE_IP},${T_START},${T_ROUTE},${CONV_MS},success" >> "$CSV"
