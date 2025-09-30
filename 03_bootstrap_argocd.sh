#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="${1:-$PWD}"
kubectl apply -k "${ROOT}/gitops/argocd"
kubectl -n argocd rollout status deploy/argocd-server --timeout=5m
echo "Initial admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
echo "Tip: port-forward with: kubectl -n argocd port-forward svc/argocd-server 8080:80"
