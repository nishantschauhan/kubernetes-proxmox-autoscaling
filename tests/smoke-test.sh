
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
head() { echo ""; echo "── $1 ──────────────────────────────────────────"; }

head "1. Cluster reachable"
if kubectl cluster-info >/dev/null 2>&1; then
  ok "kubectl can reach the cluster"
  kubectl get nodes --no-headers | while read -r n _; do echo "     node: $n"; done
else
  bad "no cluster — run: kind create cluster --config kind-cluster.yaml"
  exit 1
fi

head "2. metrics-server present (HPA cannot work without it)"
if kubectl get deployment metrics-server -n kube-system >/dev/null 2>&1; then
  if kubectl top nodes >/dev/null 2>&1; then
    ok "metrics-server installed and serving metrics"
  else
    bad "metrics-server installed but not serving — needs --kubelet-insecure-tls"
  fi
else
  bad "metrics-server missing — HPA will show <unknown> targets"
fi

head "3. Manifests apply cleanly"
if kubectl apply -f "$REPO_ROOT/manifests/workload-deployment.yaml" >/dev/null 2>&1; then
  ok "workload deployment applied"
else
  bad "workload deployment failed to apply"
fi
# NodePort override for kind (no MetalLB locally)
kubectl apply -f "$REPO_ROOT/tests/workload-nodeport.yaml" >/dev/null 2>&1 \
  && ok "test NodePort service applied" || bad "NodePort service failed"

if kubectl apply -f "$REPO_ROOT/manifests/hpa.yaml" >/dev/null 2>&1; then
  ok "HPA applied"
else
  bad "HPA failed to apply"
fi

head "4. Workload becomes Ready"
if kubectl wait --for=condition=available --timeout=120s \
     deployment/thesis-workload >/dev/null 2>&1; then
  ok "workload deployment is available"
else
  bad "workload never became available"
fi

head "5. HPA reads metrics (this is what triggers the whole loop)"
sleep 20   # HPA needs a metrics window before it reports
HPA_TARGET=$(kubectl get hpa thesis-workload-hpa -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null)
if [ -n "$HPA_TARGET" ]; then
  ok "HPA is reading CPU utilisation (currently ${HPA_TARGET}%)"
else
  bad "HPA target is <unknown> — metrics-server not working"
fi

head "6. Pending pods can be produced and DETECTED"
# Force the condition the Cluster Autoscaler reacts to, without needing load.
echo "     scaling to 60 replicas to exhaust node capacity..."
kubectl scale deployment thesis-workload --replicas=60 >/dev/null 2>&1
sleep 25

PENDING=$(kubectl get pods --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$PENDING" -gt 0 ]; then
  ok "produced $PENDING Pending pods"
else
  bad "no Pending pods — node has too much capacity; lower max-pods in kind-cluster.yaml"
fi

# Now the important one: does the watcher's own detection logic see them?
head "7. Watcher detects unschedulable pods (dry-run)"
cd "$REPO_ROOT/autoscaler"
timeout 30 python3 pending_watcher.py \
    --config-id config-a --dry-run \
    --event-log "$REPO_ROOT/results/smoke-test-events.jsonl" \
    > /tmp/watcher-out.log 2>&1
if grep -q "pending_detected" "$REPO_ROOT/results/smoke-test-events.jsonl" 2>/dev/null; then
  ok "watcher logged pending_detected"
  grep -q "scale_triggered" "$REPO_ROOT/results/smoke-test-events.jsonl" \
    && ok "watcher reached scale_triggered (would have called tofu)" \
    || echo "     (note: scale_triggered needs the grace period to elapse)"
else
  bad "watcher did not detect Pending — check /tmp/watcher-out.log"
fi
cd - >/dev/null

head "8. Analysis script runs"
if python3 "$REPO_ROOT/scripts/analyse-results.py" \
     "$REPO_ROOT/results/smoke-test-events.jsonl" >/dev/null 2>&1; then
  ok "analyse-results.py executes without error"
else
  bad "analyse-results.py errored"
fi

head "Cleanup"
kubectl scale deployment thesis-workload --replicas=1 >/dev/null 2>&1 && ok "scaled back to 1 replica"

echo ""
echo "═══════════════════════════════════════════════"
echo "  PASSED: $PASS    FAILED: $FAIL"
echo "═══════════════════════════════════════════════"
if [ "$FAIL" -eq 0 ]; then
  echo "  Kubernetes-side logic is verified."
  echo "  Remaining untested: OpenTofu → Proxmox → cloud-init → join."
else
  echo "  Fix the failures above before moving to Proxmox testing."
fi
