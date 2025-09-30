# Air‑Gapped RKE2: Fetch & Install

This repo lets you **prepare** everything online, then **install RKE2 fully offline** on the target host.
Local‑Path storage is applied by default; **Argo CD is optional** and can be bootstrapped later.

---

## Contents

```
.
├── 01_fetch_all.sh          # Run ONLINE to download RKE2 + manifests + build image bundles
├── 02_install_airgapped.sh  # Run OFFLINE on the target host to install RKE2 (+ local-path)
├── 03_bootstrap_argocd.sh   # Optional: install Argo CD later (uses patch to avoid CM duplication)
├── images.txt               # Images to bundle for use offline (MetalLB, Argo CD, cert-manager, Rancher...)
└── gitops/
    ├── storage/local-path/  # Local‑Path provisioner (default StorageClass)
    ├── argocd/              # Argo CD install.yaml + ingress + CM *patch*
    ├── metallb/             # MetalLB manifests + IP pool
    └── rendered/            # Rendered YAMLs for charts (cert‑manager, Rancher)
```

---

## Quick Start

### 1) ONLINE: Fetch all artifacts
On a machine **with internet** and Docker *or* nerdctl installed:

```bash
./01_fetch_all.sh
```

This will:
- Download RKE2 tarball, images tarball, and installer and **verify checksums**.
- Vendor manifests: Local‑Path, Argo CD (with a **ConfigMap patch** to avoid duplication), MetalLB.
- Pull Helm charts (cert‑manager, Rancher) and render to YAML (no cluster needed).
- Build an offline bundle from `images.txt` into `offline-bundles/images-<STAMP>/` and a combined tar `offline-bundles/images-<STAMP>.tar`.

> **Tip:** Adjust versions/hosts via environment variables (see [Script Environment](#script-environment)).

### 2) Copy artifacts to the target host
Copy the entire working directory to your **air‑gapped** host, e.g.:

```bash
rsync -avhP ./  user@airgap:/home/user/kubernetes/
```

### 3) (Optional) Remove network
If you want to **prove it installs offline**, physically unplug network or down the interface now.

### 4) OFFLINE: Install RKE2 and Local‑Path
On the target host, in the copied directory:

```bash
./02_install_airgapped.sh
```

What it does:
- Installs RKE2 **entirely from local files** in `vendors/rke2/<version>/`.
- Stages RKE2 core images for auto‑import and starts `rke2-server`.
- Configures `kubectl` for the current user.
- Applies **Local‑Path Provisioner** by default and waits for rollout.

> To skip Local‑Path: `SKIP_LOCAL_PATH=1 ./02_install_airgapped.sh`

### 5) (Optional) Load your offline images bundle
If you built `offline-bundles/images-<STAMP>.tar` during step 1, you can load it before doing Day‑2 installs:

```bash
BUNDLE_SRC=/path/to/offline-bundles/images-<STAMP>.tar ./02_install_airgapped.sh
```

You can also pass a directory containing `*.tar` images instead of the combined tar.

### 6) (Optional) Bootstrap Argo CD later
Argo CD is **not** installed by the base installer. When you’re ready:

```bash
./03_bootstrap_argocd.sh
```

This applies the kustomize in `gitops/argocd/` which includes:
- `install.yaml` from the selected Argo CD release
- an **Ingress** pointing to `${ARGOCD_HOST}`
- a **strategic‑merge CM patch** (`argocd-cmd-params-cm.patch.yaml`) that sets `server.insecure: true` without duplicating the resource

Get the admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Port‑forward if you don’t have DNS yet:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80
```

---

## Verifying the Cluster

```bash
kubectl get nodes
kubectl get pods -A
kubectl get storageclass
```

You should see the `local-path` StorageClass marked as default and the `local-path-provisioner` pod running in `local-path-storage` namespace.

---

## images.txt

`images.txt` lists **non‑RKE2** images you want available offline (MetalLB, Argo CD, cert-manager, Rancher, etc.).  
RKE2 core components (Canal, CoreDNS, Ingress‑NGINX, metrics-server, …) are already in the RKE2 **images tarball**, so you don’t need to list them here.

- The fetcher pulls each image, saves to individual `*.tar`, and optionally expands layers (for diffing).
- It also creates a combined bundle tar and SHA files for verification.

> **MetalLB:** Be sure to include both controller and speaker images when doing air‑gapped L2 announcements.

---

## Script Environment

### `01_fetch_all.sh`

| Variable | Default | Purpose |
|---|---|---|
| `RKE2_VER` | `v1.33.5+rke2r1` | RKE2 version to fetch (tar + images) |
| `ARCH` | auto (`amd64`/`arm64`) | CPU architecture |
| `LOCAL_PATH_REF` | `master` | Git ref for Local‑Path manifest |
| `ARGOCD_REF` | `stable` | Argo CD manifest ref (tag/branch) |
| `ARGOCD_INSECURE` | `true` | Sets `server.insecure` via **ConfigMap patch** |
| `METALLB_VER` | `v0.14.8` | MetalLB version for manifests & image hints |
| `HELM_VER` | `v3.14.4` | Helm binary to vendor |
| `RANCHER_HOST` | `rancher.local` | Used when rendering Rancher chart |
| `RANCHER_PASS` | `Admin123!` | Rancher bootstrap password |
| `ARGOCD_HOST` | `argocd.local` | Hostname used by Argo CD Ingress |
| `RANCHER_LB_IP` | `192.168.68.211` | Example fixed LB IP for Rancher service |
| `POOL_CIDRS` | `192.168.68.200-192.168.68.220` | MetalLB IPAddressPool |
| `CERTMGR_CHART_VER` | `1.18.2` | cert‑manager chart version |
| `RANCHER_CHART_VER` | `2.12.2` | Rancher chart version |
| `EXPAND_IMAGES` | `1` | Also extract layers for each saved image tar |
| `IMAGES_FILE` | (auto) | Alternate path to `images.txt` |

### `02_install_airgapped.sh`

| Variable | Default | Purpose |
|---|---|---|
| `RKE2_VER` | `v1.33.5+rke2r1` | Must match downloaded vendor directory |
| `ARCH` | auto | CPU architecture |
| `BUNDLE_SRC` | *(unset)* | Path to combined images tar **or** a dir with `*.tar` to load |
| `SKIP_LOCAL_PATH` | `0` | Set to `1` to skip Local‑Path apply |
| `WATCH` | `1` | Wait for Local‑Path deployment rollout |

---

## Useful Commands

**Service & logs**
```bash
sudo systemctl status rke2-server
journalctl -u rke2-server -f
```

**Ingress (RKE2)**
RKE2 server enables **ingress‑nginx** by default. Check controller:
```bash
kubectl -n kube-system get pods -l app.kubernetes.io/name=rke2-ingress-nginx
```

**MetalLB (optional)**
```bash
kubectl apply -k gitops/metallb
kubectl -n metallb-system get pods
```

**Rancher (optional, Day‑2)**
Rendered YAML is in `gitops/rendered/rancher.yaml`. If you load images from the bundle and have MetalLB + DNS in place, you can apply it offline.

---

## Design Notes & Gotchas

- **No Argo CD during base install.** Local‑Path is applied by default for a working default StorageClass; Argo CD is a day‑2 choice.
- **No ConfigMap duplication.** Argo CD `server.insecure` is applied via a **kustomize patch** onto the `install.yaml` CM, avoiding the ID conflict you hit when duplicating `argocd-cmd-params-cm`.
- **RKE2 images tarball is mandatory.** It contains all core images and is imported automatically by RKE2 on startup.
- **Air‑gap validation.** You can physically remove the network before running `02_install_airgapped.sh` to confirm zero external pulls.
- **Version pinning.** All defaults are pinned; override via env if you need newer/older components.

---

## Troubleshooting

- `kustomize apply` CM conflict for Argo CD  
  → This repo uses a **patch** (`argocd-cmd-params-cm.patch.yaml`) instead of creating a second CM. Use `03_bootstrap_argocd.sh` to apply.

- Local‑Path not default  
  → `kubectl get storageclass` should show the `local-path` class with `is-default-class: "true"`. If not, re‑apply `gitops/storage/local-path`.

- RKE2 not starting  
  → Check `journalctl -u rke2-server -u rke2-agent -f` and verify `/var/lib/rancher/rke2/agent/images` contains the images tarball.

- MetalLB not pulling images (air‑gap)  
  → Ensure both `quay.io/metallb/controller:<ver>` and `quay.io/metallb/speaker:<ver>` were included in `images.txt` and loaded via `BUNDLE_SRC`.

---

## License

MIT — provided as‑is, with no warranty.
