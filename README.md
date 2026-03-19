# personal-k3s-gitops

k3s 위에서 ArgoCD ApplicationSet + Helm Multi-Source 패턴으로 관리하는 GitOps 레포지토리

---

## 디렉토리 구조

```
.
├── bootstrap/
│   ├── install.sh          # 최초 1회 실행 (ArgoCD 설치 + ApplicationSet 등록)
│   └── root-appset.yaml    # ApplicationSet 진입점 (infra/* 자동 스캔)
│
├── projects/
│   ├── infra-project.yaml  # infra 앱 전용 (클러스터 리소스 허용)
│   └── apps-project.yaml   # 워크로드 앱 전용 (네임스페이스 리소스만 허용)
│
└── infra/
    ├── _template/          # 새 앱 추가 시 복사해서 사용
    ├── argocd/
    │   ├── kustomization.yaml
    │   ├── app.yaml        # ArgoCD self-managed (Multi-Source)
    │   ├── chart/
    │   │   └── values.yaml # ArgoCD Helm values
    │   └── config/
    │       ├── kustomization.yaml
    │       └── ingressroute.yaml
    └── traefik/
        ├── kustomization.yaml
        ├── app.yaml
        └── config/
            ├── kustomization.yaml
            ├── helmchartconfig.yaml
            └── ingressroute.yaml
```

---

## 아키텍처

```
Git push
  └─→ ApplicationSet (bootstrap/root-appset.yaml)
        └─→ infra/* 디렉토리 자동 스캔
              ├─→ infra/argocd  → Application: argocd  (wave -1)
              └─→ infra/traefik → Application: traefik (wave  0)
                                               └─→ IngressRoute  (wave  1)
```

### sync-wave 배포 순서

| wave | 대상 | 이유 |
|------|------|------|
| -1 | ArgoCD Helm | 가장 먼저 — self-managed 기반 |
|  0 | Traefik HelmChartConfig | ArgoCD 이후, CRD 준비 |
|  1 | ArgoCD IngressRoute | Traefik CRD 준비 이후 |

---

## 최초 배포 (1회)

```bash
# 1. 네임스페이스 및 ArgoCD 설치
cd bootstrap
bash install.sh

# 이후부터는 Git push 만으로 관리
```

---

## 새 인프라 앱 추가

```bash
# 1. 템플릿 복사
cp -r infra/_template infra/my-app

# 2. app.yaml, kustomization.yaml, chart/values.yaml 수정

# 3. Git push → ApplicationSet 이 자동으로 Application 생성
git add infra/my-app
git commit -m "feat: add my-app"
git push
```

`kustomization.yaml` 수동 편집 불필요 — 폴더 생성만으로 자동 등록

---

## AppProject 권한 분리

| 프로젝트 | 대상 | 클러스터 리소스 |
|----------|------|----------------|
| `infra`  | ArgoCD, Traefik 등 인프라 | 허용 (CRD, ClusterRole 등) |
| `apps`   | n8n, Carbone 등 워크로드  | 불허 (네임스페이스만) |

---

## Before / After

| 항목 | 기존 | 개선 |
|------|------|------|
| 진입점 | root-app (recurse: true) | ApplicationSet (Git Directory Generator) |
| 앱 추가 | kustomization.yaml 수동 편집 | 폴더 생성 후 Git push |
| ArgoCD UI | root-app 하위에 묶임 | 앱별 독립 카드 |
| 롤백 | 전체 단위 | 앱 단위 개별 롤백 |
| config 분리 | argocd-config-app.yaml 별도 | Multi-Source Source 3 으로 통합 |
| AppProject | default 하나 (권한 무제한) | infra / apps 분리 |
