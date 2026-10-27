
import argparse
import json
import statistics
from collections import defaultdict
from pathlib import Path

CONFIG_LABELS = {
    "config-a": "kubeadm / VM",
    "config-b": "kubeadm / LXC",
    "config-c": "K3s / VM",
    "config-d": "K3s / LXC",
}


def load_tts(path: Path) -> dict[str, list[float]]:
    """Extract TTS values (seconds) per config from the JSONL event log."""
    by_config: dict[str, list[float]] = defaultdict(list)
    if not path.exists():
        print(f"  (no event log at {path})")
        return by_config

    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        if ev.get("event") != "node_ready":
            continue
        detail = ev.get("detail", "")
        if "TTS_ms=" in detail:
            ms = float(detail.split("TTS_ms=")[1].split()[0])
            by_config[ev["config_id"]].append(ms / 1000.0)
    return by_config


def summarise(values: list[float]) -> dict:
    if not values:
        return {}
    return {
        "n": len(values),
        "mean": statistics.mean(values),
        "median": statistics.median(values),
        "stdev": statistics.stdev(values) if len(values) > 1 else 0.0,
        "min": min(values),
        "max": max(values),
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("event_log", nargs="?", default="../results/scale-events.jsonl")
    ap.add_argument("--csv", help="also write a CSV summary to this path")
    args = ap.parse_args()

    data = load_tts(Path(args.event_log))

    if not data:
        print("No completed scale events found yet.")
        print("Run an experiment first, then re-run this script.")
        return

    print()
    print("TIME TO SCALE BY CONFIGURATION (seconds)")
    print("=" * 78)
    print(f"{'Configuration':<20} {'n':>4} {'mean':>9} {'median':>9} "
          f"{'stdev':>9} {'min':>9} {'max':>9}")
    print("-" * 78)

    rows = []
    for cfg in ["config-a", "config-b", "config-c", "config-d"]:
        s = summarise(data.get(cfg, []))
        label = CONFIG_LABELS[cfg]
        if not s:
            print(f"{label:<20} {'-':>4} {'no data':>9}")
            continue
        print(f"{label:<20} {s['n']:>4} {s['mean']:>9.2f} {s['median']:>9.2f} "
              f"{s['stdev']:>9.2f} {s['min']:>9.2f} {s['max']:>9.2f}")
        rows.append((cfg, label, s))

    print("=" * 78)

    # --- Factor analysis: the actual thesis question ----------------------
    if len(rows) >= 2:
        print("\nFACTOR EFFECTS")
        print("-" * 78)
        vm = [v for c in ("config-a", "config-c") for v in data.get(c, [])]
        lxc = [v for c in ("config-b", "config-d") for v in data.get(c, [])]
        kubeadm = [v for c in ("config-a", "config-b") for v in data.get(c, [])]
        k3s = [v for c in ("config-c", "config-d") for v in data.get(c, [])]

        if vm and lxc:
            print(f"  Substrate:    VM mean {statistics.mean(vm):.2f}s  vs  "
                  f"LXC mean {statistics.mean(lxc):.2f}s  "
                  f"(difference {statistics.mean(vm)-statistics.mean(lxc):+.2f}s)")
        if kubeadm and k3s:
            print(f"  Distribution: kubeadm mean {statistics.mean(kubeadm):.2f}s  vs  "
                  f"K3s mean {statistics.mean(k3s):.2f}s  "
                  f"(difference {statistics.mean(kubeadm)-statistics.mean(k3s):+.2f}s)")
        print("-" * 78)
        print("  Note: these are descriptive differences only. For a claim of")
        print("  significance, run an appropriate statistical test on the raw")
        print("  samples and report the test, statistic, and p-value.")

    if args.csv:
        import csv as csvmod
        with open(args.csv, "w", newline="") as fh:
            w = csvmod.writer(fh)
            w.writerow(["config_id", "label", "n", "mean_s", "median_s",
                        "stdev_s", "min_s", "max_s"])
            for cfg, label, s in rows:
                w.writerow([cfg, label, s["n"], f"{s['mean']:.3f}",
                            f"{s['median']:.3f}", f"{s['stdev']:.3f}",
                            f"{s['min']:.3f}", f"{s['max']:.3f}"])
        print(f"\nCSV summary written to {args.csv}")


if __name__ == "__main__":
    main()
