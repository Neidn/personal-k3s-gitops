# personal-k3s-gitops

k3s 위에서 ArgoCD ApplicationSet + Helm Multi-Source 패턴으로 관리하는 GitOps 레포지토리

---

## 디렉토리 구조

```
.
├── bootstrap/
│   ├── install.sh              # 최초 1회 실행 (ArgoCD 설치 + ApplicationSet 등록)
│   ├── root-appset.yaml        # ApplicationSet 진입점 (infra/* 자동 스캔)
│   └── argocd-app.yaml         # ArgoCD self-managed Application (Multi-Source)
│
├── projects/
│   ├── infra-project.yaml      # infra 앱 전용 (클러스터 리소스 허용)
│   └── apps-project.yaml       # 워크로드 앱 전용 (네임스페이스 리소스만 허용)
│
├── infra/
│   ├── _template/              # 새 infra 앱 추가 시 복사해서 사용
│   ├── argocd/                 # ArgoCD self-managed
│   │   ├── app.yaml
│   │   ├── kustomization.yaml
│   │   ├── chart/
│   │   │   └── values.yaml     # ArgoCD Helm values
│   │   └── config/
│   │       ├── appproject.yaml
│   │       └── ingressroute.yaml
│   ├── traefik/                # k3s 기본 Traefik 설정
│   │   ├── app.yaml
│   │   ├── kustomization.yaml
│   │   └── config/
│   │       ├── helmchartconfig.yaml    # Let's Encrypt ACME, TLS, persistence
│   │       ├── middleware-ipallowlist.yaml
│   │       └── ingressroute.yaml
│   └── apps-appset/            # apps/* 자동 스캔 ApplicationSet
│       └── config/
│           └── appset.yaml
│
└── apps/
    ├── _template/              # 새 워크로드 앱 추가 시 복사해서 사용
    └── browserless/            # Chromium headless browser
        ├── app.yaml
        ├── kustomization.yaml
        └── config/
            ├── namespace.yaml
            ├── deployment.yaml
            ├── service.yaml
            ├── ingressroute.yaml
            ├── hpa.yaml
            ├── pdb.yaml
            └── secret.yaml
```

---

## 아키텍처

```
Git push
  └─→ bootstrap/root-appset.yaml       (infra/* 자동 스캔)
        ├─→ infra/argocd               → ArgoCD self-managed   (wave -1)
        ├─→ infra/traefik              → Traefik HelmChartConfig (wave 0)
        │                                └─→ IngressRoute       (wave 1)
        └─→ infra/apps-appset          → ApplicationSet for apps/*
              └─→ apps/* 자동 스캔
                    └─→ apps/browserless → Browserless Application
```

### sync-wave 배포 순서

| wave | 대상 | 이유 |
|------|------|------|
| -1 | ArgoCD Helm | self-managed 기반, 가장 먼저 |
|  0 | Traefik HelmChartConfig | ArgoCD 이후, Traefik CRD 준비 |
|  1 | IngressRoute 리소스 | Traefik CRD 준비 이후 |

---

## 최초 배포 (1회)

```bash
cd bootstrap
bash install.sh
# 이후부터는 Git push 만으로 관리
```

`install.sh` 실행 순서:
1. `argocd` 네임스페이스 생성
2. ArgoCD Helm 설치 (chart version 9.4.10)
3. AppProject 적용 (`projects/`)
4. ArgoCD self-managed Application 적용 (`bootstrap/argocd-app.yaml`)
5. root ApplicationSet 적용 (`bootstrap/root-appset.yaml`)

---

## 새 워크로드 앱 추가

```bash
# 1. 템플릿 복사
cp -r apps/_template apps/my-app

# 2. app.yaml, kustomization.yaml 수정
#    Helm 사용 시: apps/my-app/chart/values.yaml 추가

# 3. Git push → apps-appset 이 자동으로 Application 생성
git add apps/my-app
git commit -m "feat: add my-app"
git push
```

## 새 인프라 앱 추가

```bash
# 1. 템플릿 복사
cp -r infra/_template infra/my-app

# 2. app.yaml, kustomization.yaml, chart/values.yaml 수정

# 3. Git push → root-appset 이 자동으로 Application 생성
git add infra/my-app
git commit -m "feat: add my-app"
git push
```

> `kustomization.yaml` 수동 편집 불필요 — 폴더 생성만으로 자동 등록

---

## Helm Multi-Source 패턴

Helm 차트와 클러스터별 values 파일을 분리하는 패턴:

```yaml
sources:
  - repoURL: https://{helm-repo}
    chart: {chart-name}
    targetRevision: x.x.x
    helm:
      valueFiles:
        - $values/apps/{app}/chart/values.yaml
  - repoURL: https://github.com/Neidn/personal-k3s-gitops
    targetRevision: HEAD
    ref: values                    # $values 참조용
```

---

## AppProject 권한 분리

| 프로젝트 | 대상 | 클러스터 리소스 | 허용 네임스페이스 |
|----------|------|----------------|-----------------|
| `infra`  | ArgoCD, Traefik 등 인프라 | 허용 (CRD, ClusterRole 등) | argocd, kube-system, cert-manager |
| `apps`   | Browserless 등 워크로드 | 불허 (네임스페이스만) | 전체 (`*`) |

---

## 배포된 앱 목록

### 인프라

| 앱 | 네임스페이스 | 설명 |
|----|------------|------|
| argocd | argocd | GitOps 컨트롤러 (self-managed), `argocd.neidn.com` |
| traefik | kube-system | Ingress 컨트롤러, Let's Encrypt TLS, `traefik.neidn.com` |
| apps-appset | argocd | apps/* 자동 스캔 ApplicationSet |

### 워크로드

| 앱 | 네임스페이스 | 설명 |
|----|------------|------|
| browserless | browserless | Chromium headless browser, HPA(2–5), PDB(minAvailable:1) |

---

## 공통 설정

- **IP 허용 목록** (`infra/traefik/config/middleware-ipallowlist.yaml`): 모든 IngressRoute에서 공유하는 Traefik Middleware
- **TLS**: Let's Encrypt ACME HTTP challenge (`infra/traefik/config/helmchartconfig.yaml`)
- **ArgoCD**: insecure 모드 (TLS는 Traefik이 처리), ARM64 환경 최적화 리소스 설정

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
