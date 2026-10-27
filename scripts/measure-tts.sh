
set -euo pipefail

CONFIG_ID="${1:?usage: measure-tts.sh <config-id> <target-node-count> [timeout-s]}"
TARGET_NODES="${2:?usage: measure-tts.sh <config-id> <target-node-count> [timeout-s]}"
TIMEOUT_S="${3:-600}"
RESULTS_DIR="$(dirname "$0")/../results"
CSV="${RESULTS_DIR}/tts-measurements.csv"

mkdir -p "$RESULTS_DIR"
[ -f "$CSV" ] || echo "config_id,run_timestamp,t_pending_ms,t_ready_ms,tts_ms,tts_s,target_nodes,outcome" > "$CSV"

now_ms() { echo $(( $(date +%s%N) / 1000000 )); }

count_unschedulable() {
  kubectl get pods --all-namespaces -o json 2>/dev/null \
    | python3 -c '
import json,sys
d=json.load(sys.stdin)
n=0
for p in d.get("items",[]):
    s=p.get("status",{})
    if s.get("phase")!="Pending": continue
    for c in s.get("conditions",[]):
        if c.get("type")=="PodScheduled" and c.get("status")=="False" and c.get("reason")=="Unschedulable":
            n+=1; break
print(n)'
}

count_ready_nodes() {
  kubectl get nodes -o json 2>/dev/null \
    | python3 -c '
import json,sys
d=json.load(sys.stdin)
n=0
for x in d.get("items",[]):
    for c in x.get("status",{}).get("conditions",[]):
        if c.get("type")=="Ready" and c.get("status")=="True":
            n+=1; break
print(n)'
}

echo "[measure-tts] config=${CONFIG_ID} target_nodes=${TARGET_NODES} timeout=${TIMEOUT_S}s"
echo "[measure-tts] waiting for first Unschedulable pod..."

# ---- Phase 1: wait for T_pending -----------------------------------------
T_PENDING=""
DEADLINE=$(( $(date +%s) + TIMEOUT_S ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  if [ "$(count_unschedulable)" -gt 0 ]; then
    T_PENDING=$(now_ms)
    echo "[measure-tts] T_pending = ${T_PENDING}"
    break
  fi
  sleep 1
done

if [ -z "$T_PENDING" ]; then
  echo "[measure-tts] no unschedulable pod appeared — is the load high enough?"
  echo "${CONFIG_ID},$(date -Iseconds),,,,,"${TARGET_NODES}",no_pending" >> "$CSV"
  exit 1
fi

# ---- Phase 2: wait for T_ready -------------------------------------------
echo "[measure-tts] waiting for ${TARGET_NODES} Ready nodes..."
T_READY=""
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  READY=$(count_ready_nodes)
  if [ "$READY" -ge "$TARGET_NODES" ]; then
    T_READY=$(now_ms)
    echo "[measure-tts] T_ready = ${T_READY}"
    break
  fi
  sleep 1
done

if [ -z "$T_READY" ]; then
  echo "[measure-tts] TIMEOUT — target node count not reached"
  echo "${CONFIG_ID},$(date -Iseconds),${T_PENDING},,,,"${TARGET_NODES}",timeout" >> "$CSV"
  exit 1
fi

# ---- Result ---------------------------------------------------------------
TTS_MS=$(( T_READY - T_PENDING ))
TTS_S=$(python3 -c "print(f'{${TTS_MS}/1000:.2f}')")

echo "======================================================"
echo "  TIME TO SCALE : ${TTS_MS} ms  (${TTS_S} s)"
echo "  config        : ${CONFIG_ID}"
echo "======================================================"

echo "${CONFIG_ID},$(date -Iseconds),${T_PENDING},${T_READY},${TTS_MS},${TTS_S},${TARGET_NODES},success" >> "$CSV"
echo "[measure-tts] appended to ${CSV}"
