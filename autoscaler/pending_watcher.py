
import argparse
import json
import logging
import subprocess
import sys
import time
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
from pathlib import Path

# --------------------------------------------------------------------------
# Configuration defaults
# --------------------------------------------------------------------------
POLL_INTERVAL_SECONDS = 5      
SCALE_COOLDOWN_SECONDS = 120   
MAX_NODES = 6                  
PENDING_GRACE_SECONDS = 10     


def now_ms() -> int:
    """Millisecond epoch timestamp. Single source of time for all measurements."""
    return int(time.time() * 1000)


def iso_now() -> str:
    return datetime.now(timezone.utc).isoformat()



@dataclass
class ScaleEvent:
    """One row in the measurement log. One scale-up cycle produces several."""
    timestamp_ms: int
    timestamp_iso: str
    config_id: str
    event: str            # e.g. pending_detected, scale_triggered, node_ready
    pending_pods: int
    current_nodes: int
    detail: str = ""


class EventLog:
    """Appends JSONL events. Each line is independently parseable."""

    def __init__(self, path: Path):
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def write(self, event: ScaleEvent) -> None:
        with self.path.open("a") as fh:
            fh.write(json.dumps(asdict(event)) + "\n")
        logging.info("[event] %s  pending=%d nodes=%d  %s",
                     event.event, event.pending_pods,
                     event.current_nodes, event.detail)


# --------------------------------------------------------------------------
# Kubernetes interaction (via kubectl, to avoid a client library dependency)
# --------------------------------------------------------------------------
def kubectl_json(args: list[str]) -> dict:
    """Run a kubectl command and parse JSON output."""
    result = subprocess.run(
        ["kubectl", *args, "-o", "json"],
        capture_output=True, text=True, timeout=30,
    )
    if result.returncode != 0:
        raise RuntimeError(f"kubectl failed: {result.stderr.strip()}")
    return json.loads(result.stdout)


def get_unschedulable_pods() -> list[dict]:
    """
    Return pods that are Pending specifically because no node can host them.

    We filter on the FailedScheduling condition rather than simply Pending,
    because a pod can be Pending for unrelated reasons (image pull, volume
    attach). Only 'Unschedulable' means "we need more capacity" — reacting to
    anything else would inflate the measured scale-up count.
    """
    data = kubectl_json(["get", "pods", "--all-namespaces"])
    unschedulable = []

    for pod in data.get("items", []):
        status = pod.get("status", {})
        if status.get("phase") != "Pending":
            continue
        for condition in status.get("conditions", []):
            if (condition.get("type") == "PodScheduled"
                    and condition.get("status") == "False"
                    and condition.get("reason") == "Unschedulable"):
                unschedulable.append(pod)
                break
    return unschedulable


def get_ready_node_count() -> int:
    """
    Count ready WORKER nodes — excludes the control plane, which is fixed
    infrastructure (see opentofu/modules/k8s-control-plane) and is not
    governed by the worker_count variable this script scales.
    """
    data = kubectl_json(["get", "nodes"])
    ready = 0
    for node in data.get("items", []):
        labels = node.get("metadata", {}).get("labels", {})
        if "node-role.kubernetes.io/control-plane" in labels:
            continue
        for condition in node.get("status", {}).get("conditions", []):
            if condition.get("type") == "Ready" and condition.get("status") == "True":
                ready += 1
                break
    return ready


def wait_for_node_ready(target_count: int, timeout_s: int = 600) -> int | None:
    """
    Block until the cluster reports target_count Ready nodes.

    The return value is the millisecond timestamp at which the target was
    reached — this is T_ready, the second half of the Time-to-Scale metric.
    Returns None on timeout.
    """
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            if get_ready_node_count() >= target_count:
                return now_ms()
        except RuntimeError as exc:
            logging.warning("node poll failed: %s", exc)
        time.sleep(2)
    return None


# --------------------------------------------------------------------------
# CEI — Hypervisor Core Exhaustion Index (Chapter 4, §4.3.1)
# --------------------------------------------------------------------------
def compute_cei(current_nodes: int, cores_per_node: int, physical_cores: int) -> float:
    """
    CEI = total allocated vCPU / physical cores available.

    A value above 1.0 means the hypervisor is over-committed: more virtual
    cores have been promised than physically exist. Mild over-commit is normal
    in virtualisation, but past a threshold the nodes contend for CPU and the
    autoscaling latency being measured becomes a measure of contention rather
    than of provisioning. The ceiling therefore protects the VALIDITY of the
    experiment as much as the health of the host.
    """
    if physical_cores <= 0:
        return float("inf")
    return (current_nodes * cores_per_node) / physical_cores


# --------------------------------------------------------------------------
# OpenTofu interaction — step 6/7 of the control loop
# --------------------------------------------------------------------------
def trigger_scale_up(tofu_dir: Path, tfvars: str, config_id: str,
                     new_count: int, dry_run: bool) -> bool:
    """
    Raise the node count by running OpenTofu.

    Note what is happening conceptually: the ONLY thing that changes is a
    single variable, node_count. The module code is untouched. This is what
    makes the same pipeline work for all four matrix cells, and it is why the
    substrate comparison stays fair.
    """
    cmd = [
        "tofu", "apply", "-auto-approve",
        f"-var-file={tfvars}",
        f"-var=active_config={config_id}",
        f"-var=worker_count={new_count}",
    ]

    if dry_run:
        logging.info("[dry-run] would execute: %s", " ".join(cmd))
        return True

    logging.info("running: %s", " ".join(cmd))
    result = subprocess.run(cmd, cwd=tofu_dir, capture_output=True,
                            text=True, timeout=900)

    if result.returncode != 0:
        logging.error("tofu apply failed:\n%s", result.stderr[-2000:])
        return False

    logging.info("tofu apply succeeded")
    return True


# --------------------------------------------------------------------------
# Main control loop
# --------------------------------------------------------------------------
def run(args: argparse.Namespace) -> None:
    log = EventLog(Path(args.event_log))
    tofu_dir = Path(args.tofu_dir).resolve()

    logging.info("watcher started — config=%s poll=%ds cooldown=%ds",
                 args.config_id, POLL_INTERVAL_SECONDS, SCALE_COOLDOWN_SECONDS)
    logging.info("event log: %s", log.path)
    if args.dry_run:
        logging.info("DRY RUN — no provisioning will occur")

    last_scale_at = 0.0
    pending_since: float | None = None

    while True:
        try:
            pending = get_unschedulable_pods()
            nodes = get_ready_node_count()

            # ---- No pressure: reset and idle ------------------------------
            if not pending:
                if pending_since is not None:
                    logging.info("pending cleared — pods scheduled")
                    pending_since = None
                time.sleep(POLL_INTERVAL_SECONDS)
                continue

           
            if pending_since is None:
                pending_since = time.time()
                t_pending = now_ms()
                log.write(ScaleEvent(
                    timestamp_ms=t_pending, timestamp_iso=iso_now(),
                    config_id=args.config_id, event="pending_detected",
                    pending_pods=len(pending), current_nodes=nodes,
                    detail=f"first unschedulable pod: {pending[0]['metadata']['name']}",
                ))
            else:
                t_pending = int(pending_since * 1000)

            
            if time.time() - pending_since < PENDING_GRACE_SECONDS:
                time.sleep(POLL_INTERVAL_SECONDS)
                continue

            # ---- Cooldown guard -------------------------------------------
            if time.time() - last_scale_at < SCALE_COOLDOWN_SECONDS:
                time.sleep(POLL_INTERVAL_SECONDS)
                continue

            # ---- Step 5: CEI ceiling check --------------------------------
            target_nodes = nodes + 1
            cei = compute_cei(target_nodes, args.cores_per_node, args.physical_cores)

            if cei > args.cei_ceiling or target_nodes > MAX_NODES:
                log.write(ScaleEvent(
                    timestamp_ms=now_ms(), timestamp_iso=iso_now(),
                    config_id=args.config_id, event="scale_throttled",
                    pending_pods=len(pending), current_nodes=nodes,
                    detail=f"CEI {cei:.2f} exceeds ceiling {args.cei_ceiling:.2f}",
                ))
                time.sleep(SCALE_COOLDOWN_SECONDS)
                continue

            # ---- Steps 6-7: trigger provisioning --------------------------
            log.write(ScaleEvent(
                timestamp_ms=now_ms(), timestamp_iso=iso_now(),
                config_id=args.config_id, event="scale_triggered",
                pending_pods=len(pending), current_nodes=nodes,
                detail=f"target={target_nodes} CEI={cei:.2f}",
            ))

            ok = trigger_scale_up(tofu_dir, args.tfvars, args.config_id,
                                  target_nodes, args.dry_run)
            if not ok:
                log.write(ScaleEvent(
                    timestamp_ms=now_ms(), timestamp_iso=iso_now(),
                    config_id=args.config_id, event="scale_failed",
                    pending_pods=len(pending), current_nodes=nodes,
                    detail="tofu apply returned non-zero",
                ))
                last_scale_at = time.time()
                time.sleep(SCALE_COOLDOWN_SECONDS)
                continue

            # ---- Step 9: wait for the node to become Ready ----------------
         
            if not args.dry_run:
                t_ready = wait_for_node_ready(target_nodes)
                if t_ready is None:
                    log.write(ScaleEvent(
                        timestamp_ms=now_ms(), timestamp_iso=iso_now(),
                        config_id=args.config_id, event="node_ready_timeout",
                        pending_pods=len(pending), current_nodes=nodes,
                        detail="node did not reach Ready within timeout",
                    ))
                else:
                    tts_ms = t_ready - t_pending
                    log.write(ScaleEvent(
                        timestamp_ms=t_ready, timestamp_iso=iso_now(),
                        config_id=args.config_id, event="node_ready",
                        pending_pods=len(get_unschedulable_pods()),
                        current_nodes=get_ready_node_count(),
                        detail=f"TTS_ms={tts_ms}",
                    ))
                    logging.info("=== TIME TO SCALE: %d ms (%.1f s) ===",
                                 tts_ms, tts_ms / 1000)

            last_scale_at = time.time()
            pending_since = None

        except KeyboardInterrupt:
            logging.info("watcher stopped by user")
            sys.exit(0)
        except Exception as exc:  # keep the loop alive during a long experiment
            logging.exception("loop error: %s", exc)
            time.sleep(POLL_INTERVAL_SECONDS)


def main() -> None:
    p = argparse.ArgumentParser(description="Cluster Autoscaler -> Proxmox bridge")
    p.add_argument("--config-id", required=True,
                   choices=["config-a", "config-b", "config-c", "config-d"],
                   help="Which matrix cell is under test")
    p.add_argument("--tofu-dir", default="../opentofu",
                   help="Directory containing the OpenTofu configuration")
    p.add_argument("--tfvars", default="laptop.tfvars",
                   help="tfvars file: laptop.tfvars or production.tfvars")
    p.add_argument("--event-log", default="../results/scale-events.jsonl",
                   help="JSONL measurement output")
    p.add_argument("--physical-cores", type=int, default=8,
                   help="Physical cores on the Proxmox host (for CEI)")
    p.add_argument("--cores-per-node", type=int, default=2,
                   help="vCPU allocated per worker node (for CEI)")
    p.add_argument("--cei-ceiling", type=float, default=1.5,
                   help="Maximum allowed vCPU:core over-commit ratio")
    p.add_argument("--dry-run", action="store_true",
                   help="Detect and log but never provision")
    args = p.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s  %(levelname)-7s  %(message)s",
        datefmt="%H:%M:%S",
    )
    run(args)


if __name__ == "__main__":
    main()
