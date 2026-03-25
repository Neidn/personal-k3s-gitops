# personal-k3s-gitops

k3s 위에서 ArgoCD ApplicationSet + Kustomize Helm 패턴으로 관리하는 GitOps 레포지토리

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
│   ├── argocd/                 # ArgoCD self-managed (Multi-Source 예외)
│   │   ├── app.yaml
│   │   ├── kustomization.yaml
│   │   ├── chart/
│   │   │   └── values.yaml
│   │   └── config/
│   │       ├── appproject.yaml
│   │       └── ingressroute.yaml
│   ├── traefik/                # k3s 기본 Traefik 설정
│   │   ├── kustomization.yaml  # helmCharts 포함
│   │   └── config/
│   │       ├── helmchartconfig.yaml    # Let's Encrypt ACME, TLS, persistence
│   │       ├── middleware-ipallowlist.yaml
│   │       └── ingressroute.yaml
│   ├── sealed-secrets/         # Bitnami Sealed Secrets 컨트롤러
│   │   └── kustomization.yaml  # helmCharts 포함
│   └── apps-appset/            # apps/* 자동 스캔 ApplicationSet
│       └── config/
│           └── appset.yaml
│
└── apps/
    ├── _template/              # 새 워크로드 앱 추가 시 복사해서 사용
    │   ├── kustomization.yaml  # helmCharts 포함
    │   ├── ingressroute.yaml
    │   └── secret.yaml
    └── browserless/            # Chromium headless browser
        ├── kustomization.yaml  # helmCharts 포함
        ├── ingressroute.yaml
        └── secret.yaml         # SealedSecret
```

---

## 아키텍처

```
Git push
  └─→ bootstrap/root-appset.yaml       (infra/* 자동 스캔)
        ├─→ infra/argocd               → ArgoCD self-managed   (wave -1, Multi-Source)
        ├─→ infra/traefik              → Traefik HelmChartConfig (wave 0)
        │                                └─→ IngressRoute       (wave 1)
        ├─→ infra/sealed-secrets       → sealed-secrets-controller (kube-system)
        └─→ infra/apps-appset          → ApplicationSet for apps/*
              └─→ apps/* 자동 스캔
                    └─→ apps/browserless → Browserless (kustomize helmCharts)
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

## 앱 추가 패턴

### kustomize helmCharts 패턴 (표준)

`apps/*` 와 대부분의 `infra/*` 앱에서 사용. `kustomization.yaml` 에 Helm 차트를 직접 선언:

```yaml
helmCharts:
  - name: chart-name
    repo: https://helm-repo-url
    version: "x.x.x"
    releaseName: app-name
    namespace: app-name
    valuesInline:
      replicaCount: 1
      ...

resources:
  - secret.yaml       # SealedSecret
  - ingressroute.yaml # Traefik IngressRoute
```

### Multi-Source Helm 패턴 (ArgoCD 예외)

ArgoCD self-managed 앱(`infra/argocd`)에서만 사용. Helm 차트와 values 파일을 별도 소스로 분리:

```yaml
sources:
  - repoURL: https://{helm-repo}
    chart: {chart-name}
    targetRevision: x.x.x
    helm:
      valueFiles:
        - $values/infra/{app}/chart/values.yaml
  - repoURL: https://github.com/Neidn/personal-k3s-gitops
    targetRevision: HEAD
    ref: values
```

---

## 새 워크로드 앱 추가

```bash
# 1. 템플릿 복사
cp -r apps/_template apps/my-app

# 2. kustomization.yaml 의 helmCharts 블록 수정
#    ingressroute.yaml 의 REPLACE_APP_NAME 치환
#    secret.yaml 은 kubeseal 로 생성 (아래 참고)

# 3. Git push → apps-appset 이 자동으로 Application 생성
git add apps/my-app
git commit -m "feat: add my-app"
git push
```

## 새 인프라 앱 추가

```bash
# 1. 템플릿 복사
cp -r infra/_template infra/my-app

# 2. kustomization.yaml 의 helmCharts 블록 수정
#    새 Helm repo 가 있으면 projects/infra-project.yaml 의 sourceRepos 에 추가

# 3. Git push → root-appset 이 자동으로 Application 생성
git add infra/my-app
git commit -m "feat: add my-app"
git push
```

> `kustomization.yaml` 수동 편집 불필요 — 폴더 생성만으로 ApplicationSet 자동 등록

---

## Sealed Secrets 사용법

`sealed-secrets-controller` 가 `kube-system` 에 배포되어 있어, SealedSecret 을 Git 에 안전하게 커밋할 수 있음.

**Secret 생성 (최초 또는 갱신):**
```bash
kubectl create secret generic my-secret \
  --from-literal=key=값 \
  --dry-run=client -o yaml \
| kubeseal \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system \
  --format yaml \
  --namespace my-namespace \
> apps/my-app/secret.yaml
```

**마스터키 백업 (클러스터 재구성 시 필수):**
```bash
# 백업
kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-master-key-backup.yaml
# ★ 백업 파일은 절대 Git 에 올리지 말 것

# 복원
kubectl apply -f sealed-secrets-master-key-backup.yaml
kubectl rollout restart deployment sealed-secrets-controller -n kube-system
```

---

## AppProject 권한 분리

| 프로젝트 | 대상 | 클러스터 리소스 | 허용 네임스페이스 | 소스 레포 |
|----------|------|----------------|-----------------|----------|
| `infra`  | ArgoCD, Traefik, Sealed Secrets 등 | 전체 허용 (CRD, ClusterRole 등) | argocd, kube-system, cert-manager | GitHub, ArgoCD Helm, Traefik Helm, Sealed Secrets Helm (명시 필요) |
| `apps`   | Browserless 등 워크로드 | `Namespace`, `Application` 만 허용 | 전체 (`*`) | 전체 (`*`) |

- `infra` 프로젝트에 새 Helm 레포를 사용하는 앱을 추가할 때는 `projects/infra-project.yaml` 의 `sourceRepos` 에 해당 레포 URL을 추가해야 함
- `infra` 프로젝트에 새 네임스페이스가 필요한 앱을 추가할 때는 `destinations` 에도 네임스페이스를 추가해야 함
- `apps` 프로젝트는 앱 추가 시 이 파일 편집 불필요 (`sourceRepos`, `destinations` 모두 와일드카드)

---

## 배포된 앱 목록

### 인프라

| 앱 | 네임스페이스 | 설명 |
|----|------------|------|
| argocd | argocd | GitOps 컨트롤러 (self-managed), `argocd.neidn.com` |
| traefik | kube-system | Ingress 컨트롤러, Let's Encrypt TLS, `traefik.neidn.com` |
| sealed-secrets | kube-system | SealedSecret 복호화 컨트롤러 (`sealed-secrets-controller`) |
| apps-appset | argocd | apps/* 자동 스캔 ApplicationSet |

### 워크로드

| 앱 | 네임스페이스 | 설명 |
|----|------------|------|
| browserless | browserless | Chromium headless browser, HPA(2–5), `browserless.neidn.com` |

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
| Helm 관리 | ArgoCD Multi-Source (app.yaml 필요) | kustomize helmCharts (kustomization.yaml 단일 파일) |
| ArgoCD UI | root-app 하위에 묶임 | 앱별 독립 카드 |
| 롤백 | 전체 단위 | 앱 단위 개별 롤백 |
| Secret 관리 | plain Secret (Git 커밋 불가) | SealedSecret (Git 커밋 가능) |
| AppProject | default 하나 (권한 무제한) | infra / apps 분리 |
