#!/usr/bin/env bash
# 01_fetch_all.sh — ONLINE fetcher for air-gapped RKE2 + addons
#
# What it does:
#   - Downloads RKE2 tar + images tarball (+ verifies checksums)
#   - Vendors manifests/charts: local-path, Argo CD (as patch, not duplicate CM), MetalLB, cert-manager, Rancher
#   - Renders Helm charts to YAML (no cluster needed)
#   - Bundles container images (from images.txt) into offline-bundles/
#
# Usage:
#   ./01_fetch_all.sh [ROOT_DIR]
#
# Env overrides (sane defaults):
#   RKE2_VER, ARCH, LOCAL_PATH_REF, ARGOCD_REF, METALLB_VER, HELM_VER
#   RANCHER_HOST, RANCHER_PASS, ARGOCD_HOST, RANCHER_LB_IP, POOL_CIDRS
#   CERTMGR_CHART_VER, RANCHER_CHART_VER, EXPAND_IMAGES (0/1), IMAGES_FILE
#   ARGOCD_INSECURE (true/false)
#
set -Eeuo pipefail
trap 'rc=$?; echo -e "\n[ERROR] line $LINENO: $BASH_COMMAND (exit $rc)"; exit $rc' ERR

# ---------- Config ----------
ROOT="${1:-$PWD}"
RKE2_VER="${RKE2_VER:-v1.33.5+rke2r1}"
ARCH_DEFAULT="$(case "$(uname -m)" in x86_64) echo amd64;; aarch64) echo arm64;; *) echo amd64;; esac)"
ARCH="${ARCH:-$ARCH_DEFAULT}"

LOCAL_PATH_REF="${LOCAL_PATH_REF:-master}"
ARGOCD_REF="${ARGOCD_REF:-stable}"
ARGOCD_INSECURE="${ARGOCD_INSECURE:-true}"
METALLB_VER="${METALLB_VER:-v0.14.8}"
HELM_VER="${HELM_VER:-v3.14.4}"

RANCHER_HOST="${RANCHER_HOST:-rancher.local}"
RANCHER_PASS="${RANCHER_PASS:-Admin123!}"
ARGOCD_HOST="${ARGOCD_HOST:-argocd.local}"
RANCHER_LB_IP="${RANCHER_LB_IP:-192.168.68.211}"
POOL_CIDRS="${POOL_CIDRS:-192.168.68.200-192.168.68.220}"

CERTMGR_CHART_VER="${CERTMGR_CHART_VER:-1.18.2}"
RANCHER_CHART_VER="${RANCHER_CHART_VER:-2.12.2}"
EXPAND_IMAGES="${EXPAND_IMAGES:-1}"   # 1 = also expand layers for diffing

# ---------- Helpers ----------
say()  { printf '\n\033[1;36m>>> %s\033[0m\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing required command: $1"; exit 1; }; }
fetch(){ # fetch <url> <dest>
  local url="$1"
  local dest="$2"
  local part
  part="${dest}.part"
  mkdir -p "$(dirname "$dest")"
  rm -f "$part"
  curl -fsSL --retry 5 --retry-delay 2 --continue-at - -o "$part" "$url"
  mv -f "$part" "$dest"
}

need curl; need sha256sum; need tar
if command -v docker >/dev/null 2>&1; then PULLER="docker"
elif command -v nerdctl >/dev/null 2>&1; then PULLER="nerdctl"
else echo "ERROR: need either docker or nerdctl installed to pull images"; exit 1
fi

say "Creating folders"
mkdir -p \
  "${ROOT}/vendors/rke2" \
  "${ROOT}/vendors/helm" \
  "${ROOT}/gitops/storage/local-path" \
  "${ROOT}/gitops/argocd" \
  "${ROOT}/gitops/metallb/manifests" \
  "${ROOT}/gitops/rendered" \
  "${ROOT}/gitops/charts/cert-manager" \
  "${ROOT}/gitops/charts/rancher" \
  "${ROOT}/offline-bundles"
sudo chown -R "$USER:$USER" "$ROOT" 2>/dev/null || true

# ---------- RKE2 blobs (+ images tarball) ----------
say "Downloading RKE2 ${RKE2_VER} (${ARCH})"
RKE2_DEST="${ROOT}/vendors/rke2/${RKE2_VER}"; mkdir -p "${RKE2_DEST}"
ENC_VER="${RKE2_VER//+/%2B}"
BASE="https://github.com/rancher/rke2/releases/download/${ENC_VER}"
TB="rke2.linux-${ARCH}.tar.gz"
SUM="sha256sum-${ARCH}.txt"
IMGTBZ="rke2-images.linux-${ARCH}.tar.zst"

fetch "${BASE}/${TB}"      "${RKE2_DEST}/${TB}"
fetch "${BASE}/${SUM}"     "${RKE2_DEST}/${SUM}"
fetch "https://get.rke2.io" "${RKE2_DEST}/install.sh"; chmod +x "${RKE2_DEST}/install.sh"
fetch "${BASE}/${IMGTBZ}"  "${RKE2_DEST}/${IMGTBZ}"

say "Verifying RKE2 checksums"
(
  cd "${RKE2_DEST}"
  grep " ${TB}\$"     "${SUM}" | sha256sum -c -
  grep " ${IMGTBZ}\$" "${SUM}" | sha256sum -c -
)

# ---------- local-path storage ----------
say "Writing local-path storage definitions"
LP="${ROOT}/gitops/storage/local-path"
fetch "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_REF}/deploy/local-path-storage.yaml" "${LP}/local-path.yaml"
cat > "${LP}/sc-default-patch.yaml" <<'YAML'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-path
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
YAML
cat > "${LP}/kustomization.yaml" <<'YAML'
resources:
  - local-path.yaml
patches:
  - path: sc-default-patch.yaml
    target:
      kind: StorageClass
      name: local-path
YAML

# ---------- Argo CD (as patch to avoid CM duplication) ----------
say "Writing Argo CD core definitions (with CM *patch*)"
AG="${ROOT}/gitops/argocd"
mkdir -p "${AG}"
cat > "${AG}/namespace.yaml" <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: argocd
YAML

fetch "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_REF}/manifests/install.yaml" "${AG}/install.yaml"

# ensure old duplicate CM file is gone
rm -f "${AG}/argocd-cmd-params-cm.yaml" 2>/dev/null || true

# strategic-merge patch for the CM that exists inside install.yaml
cat > "${AG}/argocd-cmd-params-cm.patch.yaml" <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cmd-params-cm
  namespace: argocd
data:
  server.insecure: "${ARGOCD_INSECURE}"
YAML

cat > "${AG}/ingress-argocd.yaml" <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd
  namespace: argocd
  annotations:
    kubernetes.io/ingress.class: "nginx"
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
spec:
  rules:
  - host: ${ARGOCD_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 80
YAML

cat > "${AG}/kustomization.yaml" <<'YAML'
namespace: argocd
resources:
  - namespace.yaml
  - install.yaml
  - ingress-argocd.yaml
patches:
  - target:
      group: ""
      version: v1
      kind: ConfigMap
      name: argocd-cmd-params-cm
    path: argocd-cmd-params-cm.patch.yaml
YAML

# ---------- MetalLB ----------
say "Writing MetalLB native + address pool"
ML="${ROOT}/gitops/metallb"
fetch "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VER}/config/manifests/metallb-native.yaml" "${ML}/manifests/metallb-native.yaml"
cat > "${ML}/pool.yaml" <<YAML
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default
  namespace: metallb-system
spec:
  addresses:
    - ${POOL_CIDRS}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
spec:
  ipAddressPools:
    - default
YAML
cat > "${ML}/kustomization.yaml" <<'YAML'
resources:
  - manifests/metallb-native.yaml
  - pool.yaml
YAML

# ---------- Helm + charts ----------
say "Vendoring Helm ${HELM_VER} and charts"
HELM_DIR="${ROOT}/vendors/helm"; mkdir -p "${HELM_DIR}"
HELM_TGZ="helm-${HELM_VER}-linux-${ARCH}.tar.gz"
if [ ! -x "${HELM_DIR}/helm" ]; then
  fetch "https://get.helm.sh/${HELM_TGZ}" "${HELM_DIR}/${HELM_TGZ}"
  tar -xzf "${HELM_DIR}/${HELM_TGZ}" -C "${HELM_DIR}"
  mv -f "${HELM_DIR}/linux-${ARCH}/helm" "${HELM_DIR}/helm"; rm -rf "${HELM_DIR}/linux-${ARCH}"
  chmod +x "${HELM_DIR}/helm"
fi
HELM_BIN="${HELM_DIR}/helm"

CERT_DIR="${ROOT}/gitops/charts/cert-manager"; mkdir -p "${CERT_DIR}"
RANCHER_DIR="${ROOT}/gitops/charts/rancher"; mkdir -p "${RANCHER_DIR}"
TMP="${ROOT}/.tmp-charts"; rm -rf "${TMP}"; mkdir -p "${TMP}"

"${HELM_BIN}" pull --repo https://charts.jetstack.io cert-manager --version "${CERTMGR_CHART_VER}" --destination "${TMP}"
CERT_TGZ="$(ls -1 "${TMP}"/cert-manager-*.tgz | head -n1)"
[ -f "${CERT_TGZ}" ] || { echo "ERROR: cert-manager tgz not found in ${TMP}"; exit 1; }
tar -xzf "${CERT_TGZ}" -C "${CERT_DIR}" --strip-components=1

"${HELM_BIN}" pull --repo https://releases.rancher.com/server-charts/stable rancher --version "${RANCHER_CHART_VER}" --destination "${TMP}"
RANCHER_TGZ="$(ls -1 "${TMP}"/rancher-*.tgz | head -n1)"
[ -f "${RANCHER_TGZ}" ] || { echo "ERROR: rancher tgz not found in ${TMP}"; exit 1; }
tar -xzf "${RANCHER_TGZ}" -C "${RANCHER_DIR}" --strip-components=1

rm -rf "${TMP}"

# ---------- Render YAMLs (no cluster required) ----------
say "Rendering charts to YAML"
REN="${ROOT}/gitops/rendered"; mkdir -p "${REN}"
"${HELM_BIN}" template cert-manager "${CERT_DIR}" \
  --namespace cert-manager \
  --set installCRDs=true \
  > "${REN}/cert-manager.yaml"

"${HELM_BIN}" template rancher "${RANCHER_DIR}" \
  --namespace cattle-system \
  --set hostname="${RANCHER_HOST}" \
  --set replicas=1 \
  --set bootstrapPassword="${RANCHER_PASS}" \
  --set ingress.tls.source=rancher \
  > "${REN}/rancher.yaml"

cat > "${REN}/rancher-lb-service.yaml" <<YAML
apiVersion: v1
kind: Service
metadata:
  name: rancher-lb
  namespace: cattle-system
spec:
  type: LoadBalancer
  loadBalancerIP: ${RANCHER_LB_IP}
  selector:
    app: rancher
  ports:
  - name: https
    port: 443
    targetPort: 443
YAML

# ---------- Images bundle from images.txt ----------
say "Preparing offline image bundle"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGES_FILE_OVERRIDE="${IMAGES_FILE:-}"
IMAGES_FILE=""
for p in "${IMAGES_FILE_OVERRIDE}" "${SCRIPT_DIR}/images.txt" "${ROOT}/images.txt"; do
  [ -n "$p" ] && [ -f "$p" ] && IMAGES_FILE="$p" && break
done

if [ -z "${IMAGES_FILE}" ]; then
  echo "ERROR: images.txt not found next to this script or in ROOT. Create it and rerun."
  echo "Hint: include MetalLB images for airgap such as:"
  echo "  quay.io/metallb/controller:${METALLB_VER#v}"
  echo "  quay.io/metallb/speaker:${METALLB_VER#v}"
  exit 1
fi

say "Using images list: ${IMAGES_FILE}"
if ! grep -qE 'metallb/(controller|speaker)' "${IMAGES_FILE}" 2>/dev/null; then
  echo "WARN: images.txt seems to be missing MetalLB images (controller/speaker)."
  echo "      In air-gapped installs, MetalLB pods will fail to pull without them."
fi

TOTAL="$(grep -vE '^\s*(#|$)' "${IMAGES_FILE}" | wc -l | tr -d ' ')"
[ "${TOTAL}" -gt 0 ] || { echo "No images to process — skipping bundle"; TOTAL=0; }

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${ROOT}/offline-bundles/images-${STAMP}"
EXP="${ROOT}/offline-bundles/expanded/images-${STAMP}"
mkdir -p "${OUT}"; [ "${EXPAND_IMAGES}" = "1" ] && mkdir -p "${EXP}"

INDEX="${OUT}/images-manifest.csv"
SUMS="${OUT}/sha256s.txt"
ERRS="${OUT}/errors.log"
echo "image,tar_path,expanded_path,tar_sha256,tar_size_bytes" > "${INDEX}"
: > "${SUMS}"; : > "${ERRS}"
cp -f "${IMAGES_FILE}" "${OUT}/images.txt"

file_safe(){ echo "$1" | sed -E 's|/|__|g; s|:|__|g; s|@|__|g'; }

if [ "${TOTAL}" -gt 0 ]; then
  say "Pulling and saving ${TOTAL} image(s) with ${PULLER}"
  i=0
  while IFS= read -r raw; do
    IMG="$(echo "$raw" | sed -E 's/^\s+|\s+$//g')"
    [[ -z "$IMG" || "${IMG:0:1}" == "#" ]] && continue
    i=$((i+1)); echo "[$i/${TOTAL}] ${IMG}"
    if ! ${PULLER} pull "${IMG}"; then echo "PULL FAIL: ${IMG}" | tee -a "${ERRS}"; continue; fi
    SAFE="$(file_safe "${IMG}")"
    TAR="${OUT}/${SAFE}.tar"
    if ! ${PULLER} save -o "${TAR}" "${IMG}"; then echo "SAVE FAIL: ${IMG}" | tee -a "${ERRS}"; continue; fi
    SHA="$(sha256sum "${TAR}" | awk '{print $1}')"
    SIZ="$(stat -c%s "${TAR}" 2>/dev/null || wc -c < "${TAR}")"
    echo "${SHA}  ${SAFE}.tar" >> "${SUMS}"
    EXP_PATH=""
    if [ "${EXPAND_IMAGES}" = "1" ]; then
      EXP_PATH="${EXP}/${SAFE}"; mkdir -p "${EXP_PATH}"
      tar -xf "${TAR}" -C "${EXP_PATH}" || echo "EXPAND FAIL: ${IMG}" | tee -a "${ERRS}"
    fi
    echo "${IMG},${TAR},${EXP_PATH},${SHA},${SIZ}" >> "${INDEX}"
  done < <(grep -vE '^\s*(#|$)' "${IMAGES_FILE}")

  COMBINED="${OUT}.tar"
  tar -C "${OUT}" -cf "${COMBINED}" .
  ( cd "${OUT}" && sha256sum *.tar | sort -k2 ) > "${OUT}/sha256s.per-image.txt"
  sha256sum "${COMBINED}" > "${OUT}/combined.sha256"
fi

# ---------- Summary ----------
say "DONE. Artifacts:"
echo "  RKE2 blobs     : ${RKE2_DEST}"
echo "    - ${TB}"
echo "    - ${IMGTBZ}"
echo "    - install.sh"
echo "  Rendered YAMLs : ${ROOT}/gitops/rendered"
echo "  Helm charts    : ${ROOT}/gitops/charts/{cert-manager,rancher}"
if [ "${TOTAL}" -gt 0 ]; then
  echo "  Per-image tars : ${OUT}"
  [ "${EXPAND_IMAGES}" = "1" ] && echo "  Expanded layers: ${EXP}"
  echo "  Combined bundle: ${OUT}.tar"
  [ -s "${ERRS}" ] && { echo "  NOTE: Some images failed (see ${ERRS})"; } || true
else
  echo "  No images were bundled (empty images.txt)."
fi
