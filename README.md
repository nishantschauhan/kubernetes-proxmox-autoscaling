# thesis-infra

Infrastructure and measurement code for the master's thesis
**"Comparative Evaluation of Kubernetes Autoscaling on a Proxmox VE Private Cloud"**
(Hof University of Applied Sciences).

This repository *is* the reproducibility claim made in Chapter 3. Everything
needed to recreate the experiment lives here, in version control.

---

## 1. What problem this code solves

On a managed cloud, the Kubernetes Cluster Autoscaler ships with a provider
plugin that knows how to create nodes. **On Proxmox, that plugin does not
exist.** The autoscaler can decide that more capacity is needed but has no way
to act on it.

This repository builds that missing bridge, and instruments it so the
resulting behaviour can be measured across four configurations:

|            | Ubuntu VM (QEMU) | Proxmox LXC |
|------------|------------------|-------------|
| **kubeadm**| `config-a`       | `config-b`  |
| **K3s**    | `config-c`       | `config-d`  |

The experimental claim depends on **only** the distribution and the substrate
changing between cells. Everything else — provisioning tool, workload, HPA
threshold, load profile, instrumentation — is held constant by design.

---

## 2. How the pieces fit together

```
   JMeter (laptop)
        │  HTTP load
        ▼
   ┌─────────────────────── FreeBSD edge gateway ──────────────────────┐
   │  pf.conf      → stateful firewall, default deny                   │
   │  haproxy.cfg  → distributes traffic across worker nodes           │
   │  frr.conf     → BGP peer, learns routes from the cluster          │
   └───────────────────────────────┬───────────────────────────────────┘
                                   │ BGP session (TCP 179)
   ┌───────────────────────────────▼───────────────────────────────────┐
   │                    Proxmox VE (bare metal)                        │
   │                                                                   │
   │   Kubernetes cluster                                              │
   │     workload-deployment.yaml  → the app under load                │
   │     hpa.yaml                  → 80% CPU → more pods → Pending     │
   │     metallb-config.yaml       → advertises routes over BGP        │
   │                                   ▲                               │
   └───────────────────────────────────┼───────────────────────────────┘
                                       │ watches for Pending pods
                    ┌──────────────────┴───────────────────┐
                    │  autoscaler/pending_watcher.py       │
                    │  (the component that does not exist  │
                    │   off the shelf — the contribution)  │
                    └──────────────────┬───────────────────┘
                                       │ raises node_count
                    ┌──────────────────▼───────────────────┐
                    │  opentofu/  →  Proxmox REST API      │
                    │  clones a VM or LXC from a template  │
                    └──────────────────┬───────────────────┘
                                       │
                    cloud-init (VM) or bootstrap script (LXC)
                                       │
                              node joins the cluster
                                       │
                          Pending pods scheduled — loop closes
```

---

## 3. File-by-file: what each thing does

### `opentofu/` — declarative provisioning

| File | Role |
|---|---|
| `providers.tf` | The only file that talks to Proxmox. Every value is a variable, so it is **never edited** when moving to hardware. |
| `variables.tf` | Declares every environment-specific input. The contract between code and environment. |
| `main.tf` | Decodes `active_config` (a/b/c/d) into distro + substrate and calls the matching module. |
| `outputs.tf` | Node names/IPs, consumed by the measurement scripts. |
| `laptop.tfvars` | Development values. |
| `production.tfvars.example` | Template for the real server. Copy to `production.tfvars` (gitignored) and fill in. |
| `modules/k8s-vm-node/` | Clones a QEMU VM, attaches cloud-init. |
| `modules/k8s-lxc-node/` | Creates an LXC container, bootstraps over SSH. |

**Why two modules with identical inputs and outputs?** So `main.tf` can call
either one without special-casing. The symmetry is what lets the thesis claim
the substrate is the only thing that changed.

### `cloud-init/` — node bootstrapping

| File | Used by | Mechanism |
|---|---|---|
| `kubeadm-vm.yaml` | config-a | cloud-init drive (declarative) |
| `k3s-vm.yaml` | config-c | cloud-init drive (declarative) |
| `kubeadm-lxc.sh` | config-b | SSH + remote-exec (imperative) |
| `k3s-lxc.sh` | config-d | SSH + remote-exec (imperative) |

> **A genuine finding to report in Chapter 5:** Proxmox LXC containers have no
> cloud-init drive, so the LXC cells need an extra imperative bootstrap step
> the VM cells do not. Compare `kubeadm-vm.yaml` against `k3s-vm.yaml` too —
> the K3s file is dramatically shorter, because K3s ships its runtime in one
> binary. Both asymmetries are results, not inconveniences.

### `manifests/` — what runs inside the cluster

- `workload-deployment.yaml` — the CPU-bound app JMeter drives. Its
  `resources.requests.cpu` is load-bearing: it is the HPA's denominator *and*
  the scheduler's capacity unit. Without it, nothing autoscales.
- `hpa.yaml` — the 80% CPU threshold. Creates the *pressure*; does not scale
  nodes. Keep identical across all four cells.
- `metallb-config.yaml` — cluster half of the BGP peering.

### `edge/` — the FreeBSD gateway

- `pf.conf` — default-deny stateful firewall.
- `haproxy.cfg` — traffic distribution, with DNS re-resolution so autoscaled
  nodes are picked up without manual edits.
- `frr.conf` — gateway half of the BGP peering. Uses a `listen range` so any
  new node can peer without editing this file.

### `autoscaler/pending_watcher.py` — the contribution

Watches for unschedulable pods, checks the CEI ceiling, triggers OpenTofu,
waits for the node to become Ready, and logs every transition with
millisecond timestamps. **This log is the raw data for the results chapter.**

### `scripts/` — measurement

- `measure-tts.sh` — independent TTS measurement via `kubectl`, for
  cross-checking the watcher's own numbers.
- `measure-bgp-convergence.sh` — how long after a node is Ready its route
  actually reaches the gateway (validates the zero-downtime claim).
- `analyse-results.py` — turns raw logs into per-config statistics and factor
  effects, ready for the results chapter.

---

## 4. What to do now (no hardware needed)

### Install

```bash
# OpenTofu
curl -fsSL https://get.opentofu.org/install-opentofu.sh | sh -s -- --install-method standalone

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -m 0755 kubectl /usr/local/bin/kubectl

# JMeter needs Java
sudo apt install -y default-jdk git python3
# then download JMeter from https://jmeter.apache.org/download_jmeter.cgi
```

### Generate your SSH key first

Everything else references it, so do this before editing any file:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/thesis_key -C "thesis-infra"
cat ~/.ssh/thesis_key.pub          # paste into laptop.tfvars
```

### Validate what you can, offline

```bash
cd opentofu
tofu init          # downloads the bpg/proxmox provider
tofu fmt -check    # formatting
tofu validate      # syntax + internal consistency

cd ..
kubectl apply --dry-run=client -f manifests/workload-deployment.yaml
kubectl apply --dry-run=client -f manifests/hpa.yaml
python3 -m py_compile autoscaler/pending_watcher.py
bash -n scripts/measure-tts.sh
python3 scripts/analyse-results.py     # works with an empty log
```

### Start the git history today

```bash
git init && git add . && git commit -m "Initial thesis infrastructure"
```

---

## 5. Hardware day: the migration

The whole design exists to make this short.

1. Install **Proxmox VE 9** on the bare metal.
2. Create an API token: *Datacenter → Permissions → API Tokens*.
3. Build the two templates:
   ```bash
   # LXC template
   pveam update && pveam download local ubuntu-22.04-standard_22.04-1_amd64.tar.zst

   # VM template from an Ubuntu cloud image
   qm create 9000 --name ubuntu-2204-template --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0
   qm importdisk 9000 jammy-server-cloudimg-amd64.img local-lvm
   qm set 9000 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-9000-disk-0
   qm set 9000 --ide2 local-lvm:cloudinit --boot c --bootdisk scsi0 --serial0 socket
   qm template 9000
   ```
4. Enable **Snippets** on the `local` storage (needed to upload cloud-init).
5. On the Proxmox host, load the kernel modules the LXC cells need:
   ```bash
   modprobe overlay br_netfilter
   echo -e "overlay\nbr_netfilter" > /etc/modules-load.d/k8s.conf
   ```
6. `cp production.tfvars.example production.tfvars` and fill in every `< >`.
7. **Provision one node only** and confirm it joins:
   ```bash
   tofu plan  -var-file=production.tfvars -var=active_config=config-a
   tofu apply -var-file=production.tfvars -var=active_config=config-a
   kubectl get nodes
   ```
8. Only then bring up the edge gateway, MetalLB, monitoring, and start runs.

**No module code changes in any of this.** Only `production.tfvars`.

---

## 6. Running an experiment

```bash
# 1. Point kubectl at the cluster for this cell
export KUBECONFIG=~/.kube/config-config-a

# 2. Deploy workload and HPA
kubectl apply -f manifests/workload-deployment.yaml
kubectl apply -f manifests/hpa.yaml

# 3. Start the watcher (terminal 1)
cd autoscaler
python3 pending_watcher.py --config-id config-a \
    --tfvars production.tfvars \
    --physical-cores 16 --cores-per-node 2 --cei-ceiling 1.5

# 4. Start the independent measurement (terminal 2)
./scripts/measure-tts.sh config-a 2

# 5. Apply load (terminal 3)
jmeter -n -t jmeter/load-test-plan.jmx -l results/run-a-01.jtl \
       -Jhost=192.168.1.200 -Jthreads=200 -Jrampup=60 -Jduration=600

# 6. Repeat at least 5 times per cell, then analyse
python3 scripts/analyse-results.py results/scale-events.jsonl --csv results/summary.csv
```

Repeat for `config-b`, `config-c`, `config-d`.

---

## 7. Known issues you will hit

These are expected. Budget time for them.

| Symptom | Cause | Fix |
|---|---|---|
| kubelet crashloops in LXC | Missing nesting/keyctl, or `/dev/kmsg` absent | `unprivileged=false`, `nesting=1`, `keyctl=1`; the bootstrap script symlinks `/dev/kmsg` |
| `modprobe` fails inside LXC | Containers share the host kernel and cannot load modules | Load `overlay` and `br_netfilter` **on the Proxmox host** |
| cloud-init never runs on LXC | LXC has no cloud-init drive | By design — LXC uses the `.sh` bootstrap path instead |
| BGP session never establishes | PF blocking TCP 179, or ASN mismatch | Check `vtysh -c "show bgp summary"`; ASNs must match between `frr.conf` and `metallb-config.yaml` |
| OpenTofu cannot upload snippets | Snippets content type not enabled on storage | Enable it in *Datacenter → Storage → local → Content* |
| Nothing ever goes Pending | Load too low, or `requests.cpu` too small | Raise JMeter threads, or raise `requests.cpu` so fewer pods fill a node |

---

## 8. Mapping to the thesis chapters

| Chapter | Corresponding code |
|---|---|
| Ch. 3 — FR-1 IaC automation | `opentofu/` |
| Ch. 3 — FR-2 autoscaling loop | `autoscaler/`, `manifests/hpa.yaml` |
| Ch. 3 — FR-3 zero-downtime sync | `manifests/metallb-config.yaml`, `edge/frr.conf` |
| Ch. 3 — FR-4 load balancing | `edge/haproxy.cfg` |
| Ch. 3 — §3.4 monitoring | `monitoring/`, `scripts/` |
| Ch. 4 — §4.2 edge design | `edge/` |
| Ch. 4 — §4.3 control loop | `autoscaler/pending_watcher.py` |
| Ch. 4 — §4.4 2×2 matrix | `opentofu/main.tf` (`active_config`) |
| Ch. 5 — implementation | all of the above, described in prose |
| Ch. 6 — results | `results/`, `scripts/analyse-results.py` |
