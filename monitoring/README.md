# Monitoring

## What each component gives the thesis

| Component | Provides | Used for |
|---|---|---|
| **Prometheus** | Time-series metrics from nodes, pods, and the Proxmox host | TTS cross-check, resource overhead, CEI |
| **kube-state-metrics** | `kube_node_status_condition`, `kube_pod_status_phase` | Counting Ready nodes and Pending pods over time |
| **node-exporter** | Per-node CPU/memory/disk | Resource overhead comparison between VM and LXC |
| **Grafana** | Dashboards and PNG/CSV export | Figures for the results chapter |
| **pve-exporter** | Proxmox host metrics | CEI numerator/denominator, host contention |

## Key PromQL queries for the results chapter

```promql
# Ready node count over time — shows the scale-up step
sum(kube_node_status_condition{condition="Ready",status="true"})

# Pending pods — the signal the autoscaler reacts to
sum(kube_pod_status_phase{phase="Pending"})

# Per-node CPU utilisation — resource overhead comparison
100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[1m])) * 100)

# Memory overhead per node (VM vs LXC comparison)
node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes

# CEI numerator: total vCPU allocated to thesis nodes
sum(kube_node_status_capacity{resource="cpu"})
```

## Grafana dashboard to build

One dashboard, four panels, is enough for the thesis:

1. **Ready nodes** (stat + time series) — the scale-up step is visible here
2. **Pending pods** (time series) — overlay with panel 1 to show the gap = TTS
3. **CPU per node** (time series, one series per node) — shows the new node taking load
4. **Request rate / latency** (from JMeter or the service) — shows service continuity

Export each as PNG for the thesis, and export the underlying data as CSV so
your figures are reproducible from raw numbers.
