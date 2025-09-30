#!/usr/bin/env bash
# 02_install_airgapped.sh — minimal offline RKE2 install (+ local-path by default; no Argo CD)
#
# Usage:
#   ./02_install_airgapped.sh
#
# Optional env:
#   BUNDLE_SRC=/path/to/images-<stamp>.tar   # or a directory containing *.tar
#   SKIP_LOCAL_PATH=1                        # set to skip applying local-path
#   WATCH=1                                  # wait for local-path rollout (default 1)
#
set -Eeuo pipefail

ROOT="${1:-$PWD}"
RKE2_VER="${RKE2_VER:-v1.33.5+rke2r1}"
ARCH_DEFAULT="$(case "$(uname -m)" in x86_64) echo amd64;; aarch64) echo arm64;; *) echo amd64;; esac)"
ARCH="${ARCH:-$ARCH_DEFAULT}"
RKE2_DEST="${ROOT}/vendors/rke2/${RKE2_VER}"
WATCH="${WATCH:-1}"

echo ">>> Installing RKE2 from local artifacts: ${RKE2_DEST}"
[ -x "${RKE2_DEST}/install.sh" ] || { echo "ERROR: ${RKE2_DEST}/install.sh not found"; exit 1; }

# Install fully offline
sudo INSTALL_RKE2_METHOD=tar \
     INSTALL_RKE2_ARTIFACT_PATH="${RKE2_DEST}" \
     sh "${RKE2_DEST}/install.sh"

# Stage core images for auto-import
echo ">>> Staging RKE2 core images"
sudo install -d -m 0755 /var/lib/rancher/rke2/agent/images
if [ -f "${RKE2_DEST}/rke2-images.linux-${ARCH}.tar.zst" ]; then
  sudo cp -f "${RKE2_DEST}/rke2-images.linux-${ARCH}.tar.zst" /var/lib/rancher/rke2/agent/images/
else
  echo "WARN: ${RKE2_DEST}/rke2-images.linux-${ARCH}.tar.zst not found"
fi
# (Optional) speeds up restarts on recent RKE2
sudo touch /var/lib/rancher/rke2/agent/images/.cache.json || true

# Start server
echo ">>> Enabling & starting rke2-server"
sudo systemctl enable --now rke2-server

# Wait for API
echo ">>> Waiting for Kubernetes API..."
for i in {1..120}; do
  if [ -f /etc/rancher/rke2/rke2.yaml ] && \
     sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig=/etc/rancher/rke2/rke2.yaml get --raw=/readyz >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

# kubectl for current user
echo ">>> Configuring kubectl"
sudo ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl
mkdir -p "${HOME}/.kube"
sudo cp /etc/rancher/rke2/rke2.yaml "${HOME}/.kube/config"
sudo chown "$(id -u)":"$(id -g)" "${HOME}/.kube/config"
export KUBECONFIG="${HOME}/.kube/config"

# -------- OPTIONAL: load addon image bundle (no Argo CD here) --------
if [ -n "${BUNDLE_SRC:-}" ]; then
  echo ">>> Loading addon images from: ${BUNDLE_SRC}"
  SRC="${BUNDLE_SRC}"
  CLEANUP=0
  if [ -f "$SRC" ] && [[ "$SRC" == *.tar ]]; then
    TMP="$(mktemp -d)"; tar -C "$TMP" -xf "$SRC"; SRC="$TMP"; CLEANUP=1
  fi
  if command -v nerdctl >/dev/null 2>&1; then LOADER=(sudo nerdctl load -i)
  elif command -v docker   >/dev/null 2>&1; then LOADER=(sudo docker load -i)
  else LOADER=(sudo /var/lib/rancher/rke2/bin/ctr -n k8s.io images import); fi
  shopt -s nullglob
  files=( "$SRC"/*.tar )
  for t in "${files[@]}"; do
    echo " - $(basename "$t")"; "${LOADER[@]}" "$t"
  done
  [ "$CLEANUP" = 1 ] && rm -rf "$TMP"
fi

# -------- local-path storage (default ON) --------
if [ "${SKIP_LOCAL_PATH:-0}" != "1" ]; then
  echo ">>> Applying local-path-provisioner (default)"
  LP_DIR="${ROOT}/gitops/storage/local-path"
  [ -f "${LP_DIR}/kustomization.yaml" ] || { echo "ERROR: missing ${LP_DIR}/kustomization.yaml (run 01_fetch_all.sh)"; exit 1; }
  kubectl apply -k "${LP_DIR}"
  if [ "${WATCH}" = "1" ]; then
    kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=3m || true
  fi
else
  echo ">>> SKIP_LOCAL_PATH=1 — not applying local-path"
fi

echo ">>> Done. RKE2 is up (no Argo CD installed here)."
echo "Hint: Use ./03_bootstrap_argocd.sh later when you want Argo CD."
