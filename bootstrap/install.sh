#!/bin/bash
# =============================================================================
# Bootstrap: ArgoCD 최초 설치 (1회만 실행)
# =============================================================================
set -euo pipefail

REPO_URL="https://github.com/Neidn/personal-k3s-gitops"
ARGOCD_VERSION="9.4.10"

echo ""
echo "▶ [1/5] 네임스페이스 생성"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "▶ [2/5] Helm repo 추가 및 ArgoCD 설치"
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update argo
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --version "${ARGOCD_VERSION}" \
  --values ../infra/argocd/chart/values.yaml \
  --wait --timeout 5m

echo ""
echo "▶ [3/5] AppProject 생성 (infra / apps 권한 분리)"
kubectl apply -f ../projects/

echo ""
echo "▶ [4/5] ArgoCD self-managed Application 적용"
# Multi-Source 특수케이스 → ApplicationSet 스캔 대상 외로 직접 관리
kubectl apply -f ./argocd-app.yaml

echo ""
echo "▶ [5/5] infra ApplicationSet 진입점 적용"
kubectl apply -f ./root-appset.yaml

echo ""
echo "완료"
echo "  ArgoCD UI : https://argocd.neidn.com"
echo "  초기 admin 패스워드:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo ""
