# `#20` 로컬 쿠버네티스에 ArgoCD 를 올려 manual sync 로 연습한다

이슈 `#20` · 2026-10-19 · 승조(`@SeungJo-02`)

9단계 틀로 쓴다. 3 · 6 절은 승조 차례(질문과 선택)이고 8절은 구현 프롬프트다.

> `#14` 가 매니페스트를 만들고 **순서는 `scripts/up-local.sh` 가** 지켰다(묶음 `apply -k` → `kubectl wait`). ADR `#66` ② 는 「배포 도구가 서면 훅으로 옮긴다」고 정했다. 이번은 그 옮기기를 로컬에서 먼저 해 보는 일이다. EKS 의 자동 sync(6단계)는 여기서 익힌 모양을 그대로 쓴다.

---

## 1. 무엇을 하려는 것인가

로컬 쿠버네티스에 ArgoCD 를 올리고, `#14` 매니페스트를 **사람이 sync 버튼을 눌러** 넣어 본다.

### 지금과 달라지는 것

| | 지금 (`#14`) | 이번 |
|---|---|---|
| 클러스터에 넣는 것 | 내 컴퓨터의 `up-local.sh` 가 `kubectl apply -k` | **ArgoCD 가 GitHub 의 이 레포를 읽어** 넣는다 |
| 순서 | 묶음 사이 `kubectl wait` | ArgoCD **sync wave · hook** |
| 「지금 레포와 클러스터가 같은가」 | 알 길이 없다 | UI 에 `Synced` / `OutOfSync` 로 보인다 |
| 언제 넣나 | 스크립트를 칠 때 | sync 를 누를 때 (manual). 자동은 6단계 EKS |

### 왜 로컬에서 먼저인가

| 이유 | 근거 |
|---|---|
| 일정 | `docs/plan.md` 3단계. Terraform(`#17`) 과 병행이고 이번엔 먼저 한다 (10/19 ~ 22, 막히면 끊는다) |
| 돈이 안 든다 | EKS 는 켜는 순간 고정비(EKS · NAT)가 붙는다 (`#9`) |
| EKS 에서 처음 겪으면 원인이 두 겹이다 | EKS 쪽 문제(권한 · 네트워크)와 ArgoCD 쪽 문제(순서 · 훅)가 섞인다. 로컬에서 ArgoCD 쪽을 먼저 걸러 둔다 |

### 연습할 것 셋 (`docs/plan.md` 3단계)

- **App of Apps** : Application 하나가 나머지 Application 들을 거느리는 모양
- **sync 실패 읽기** : 일부러 틀린 매니페스트를 넣고 원인을 UI · CLI 에서 읽는다
- **prune 영향** : 레포에서 지운 자원을 ArgoCD 가 지우는지, 저장소 볼륨은 어떻게 되는지

### 이미 정해져 있는 것 (다시 정하지 않는다)

| 무엇 | 어디서 |
|---|---|
| 이미지 태그는 CI 가 이 레포에 커밋한다. **Argo CD Image Updater 는 쓰지 않는다** | ADR `#62` H |
| 순서 장치는 손으로 시작하고 **배포 도구가 서면 훅으로 옮긴다** | ADR `#66` ①② |
| 로컬은 manual sync, 자동 sync 는 EKS (6단계) | `docs/plan.md` |
| 매니페스트는 생 YAML + kustomize overlay, 넣는 곳은 `overlays/` | `#14` |
| 비밀값 · 마이그레이션 SQL · 인증서는 레포에 두지 않는다 | `AGENTS.md` §2 |
| 클러스터 입구는 화면 · API 만. ArgoCD UI 는 입구에 두지 않는다 (로컬은 `port-forward`) | `#11` · ADR `#62` |

---

## 2. 꼭 알아야 하는 것 여섯

### 2.1 ArgoCD 는 「레포를 읽어 클러스터를 맞추는」 프로그램이다

- 클러스터 안에 파드 몇 개로 뜬다 (네임스페이스 `argocd`)
  - `repo-server` : GitHub 에서 레포를 받아 `kustomize build` 를 돌려 「이래야 한다」를 만든다
  - `application-controller` : 그것과 클러스터의 실제 모습을 비교하고, sync 를 누르면 차이를 넣는다
  - `server` : UI · API · CLI 가 붙는 곳
  - `redis` · `dex`(로그인 연동, 로컬은 안 쓴다) · `applicationset-controller` · `notifications-controller`
- 무엇을 어디에 넣을지는 **Application** 이라는 자원 하나에 적는다

  ```yaml
  kind: Application
  spec:
    source:
      repoURL: https://github.com/2026-techeer-project-team-b/monimo-deploy
      targetRevision: develop          # 어느 브랜치(또는 태그 · 커밋)를 읽나
      path: overlays/local/3-apps      # 그 안의 어느 폴더. kustomization.yaml 이 있으면 kustomize 로 읽는다
    destination:
      server: https://kubernetes.default.svc   # 자기가 떠 있는 클러스터
    syncPolicy: {}                     # 비우면 manual sync. automated 를 적으면 자동
  ```

- **중요** : ArgoCD 는 **GitHub 에 push 된 것**을 읽는다. 내 컴퓨터에서 고친 파일은 push 전까지 안 보인다 (`up-local.sh` 와 가장 다른 점, 5.5)
- 레포가 공개라 읽을 때 인증이 필요 없다

### 2.2 sync wave 와 hook : `kubectl wait` 를 대신하는 것

**sync wave (번호표)**

- 자원마다 `argocd.argoproj.io/sync-wave: "<숫자>"` 주석을 붙인다. 안 붙이면 0
- ArgoCD 는 **작은 번호부터** 넣고, 그 번호의 자원이 전부 **Healthy** 가 된 뒤 다음 번호로 간다
- 「Healthy」의 뜻은 종류마다 ArgoCD 가 정해 둔 것이다 : StatefulSet · Deployment 는 파드가 준비됐을 때, Job 은 성공 종료했을 때
- 그래서 `#14` 의 순서를 이렇게 옮길 수 있다

  ```
  wave 0  네임스페이스
  wave 1  저장소 셋 (StatefulSet)          ← Healthy = 파드 Ready  (= up-local.sh 1 의 wait)
  wave 2  준비 Job 셋                      ← Healthy = 성공 종료    (= up-local.sh 2 의 wait)
  wave 3  수집기 · 적재 처리기               ← Healthy = 파드 Ready  (= up-local.sh 3 의 wait)
  ```

**hook (특정 시점에 한 번 도는 것)**

- `argocd.argoproj.io/hook: PreSync | Sync | PostSync | SyncFail` 주석을 붙인 자원은 「늘 있어야 하는 것」이 아니라 **sync 할 때마다 한 번 도는 것**이 된다
  - PreSync : 본 자원을 넣기 전에 (예 : 마이그레이션)
  - PostSync : 본 자원이 다 Healthy 가 된 뒤에 (예 : 관통 확인)
- 지우는 시점은 `argocd.argoproj.io/hook-delete-policy` 로 고른다 : `BeforeHookCreation`(다음 sync 때 지우고 새로) · `HookSucceeded`(성공하면 바로) · `HookFailed`
- ADR `#66` ② 의 「훅으로 옮긴다」가 이것이다

### 2.3 Job 은 내용을 못 고친다 : ArgoCD 에서 가장 먼저 걸리는 곳

- 쿠버네티스 Job 은 한 번 만들면 `spec.template` 을 바꿀 수 없다 (`field is immutable`)
- `#14` 는 그래서 스크립트가 Job 을 **지우고 새로** 만들었다 (`rerun_job`)
- ArgoCD 에 Job 을 **보통 자원**으로 두면 : 이미지 태그 하나만 바꿔도 sync 가 `field is immutable` 로 실패한다 · 성공한 Job 이 계속 남아 있어 「다시 돌리기」가 없다
- 길은 셋이다 (5.3)
  - hook 으로 둔다 : 매 sync 마다 새로 만들어 돈다 (`BeforeHookCreation`)
  - 보통 자원 + `argocd.argoproj.io/sync-options: Replace=true` : 바뀌면 지우고 다시 만든다
  - 보통 자원 + `ttlSecondsAfterFinished` : 끝나면 쿠버네티스가 지운다. 그러면 ArgoCD 는 「없어졌다」를 OutOfSync 로 본다

### 2.4 App of Apps : Application 을 Application 으로 넣는다

- Application 도 쿠버네티스 자원이라 **레포에 YAML 로 두고 ArgoCD 가 넣게** 할 수 있다
- 「뿌리」 Application 하나만 손으로 넣으면, 그게 `argocd/` 폴더를 읽어 나머지 Application 들을 만든다

  ```
  root (손으로 한 번)
   ├ local-namespaces    → overlays/local/0-namespaces
   ├ local-infra         → overlays/local/1-infra
   ├ local-jobs          → overlays/local/2-jobs
   └ local-apps          → overlays/local/3-apps
  ```

- **알려진 함정 (구현 때 확인)** : Application **끼리**의 순서를 sync wave 로 지키려면, ArgoCD 가 「자식 Application 이 Healthy 인가」를 알아야 한다. ArgoCD 는 v1.8 부터 이 판단을 기본으로 끄고 설정(`argocd-cm` 의 Application 상태 판정)을 따로 넣게 했다. 3.x 에서도 같은지는 설치 뒤 실제로 본다. 안 넣으면 wave 가 순서를 안 지키고 한꺼번에 넣는다

### 2.5 prune 과 저장소 볼륨 : 지울 때 무엇이 같이 지워지나

- **prune** : 레포에서 지운 자원을 클러스터에서도 지우는 것. manual sync 에서는 sync 창에서 `Prune` 을 체크해야만 지운다
- 지워지는 범위가 자원마다 다르다

| 레포에서 지운 것 | prune 하면 |
|---|---|
| Deployment | 파드까지 지워진다. 남는 것 없음 |
| StatefulSet | 파드는 지워지지만 **PVC 는 남는다** : PVC 는 ArgoCD 가 아니라 StatefulSet 이 만든 것이라 ArgoCD 가 모른다 |
| **Namespace** | **그 안의 전부가 지워진다 : PVC 포함.** 로컬 `hostpath` 는 회수 정책이 `Delete` 라 데이터까지 사라진다 (`#14` 9절 실측) |

- 그래서 네임스페이스를 ArgoCD 가 관리하게 할지, 관리하되 지우지는 못하게 할지(`argocd.argoproj.io/sync-options: Prune=false`)를 정해야 한다 (5.4)
- EKS 에서는 같은 실수가 EBS 를 지울 수 있다. 그쪽은 `Retain` 이라 볼륨은 남지만(ADR `#62` F) 파드는 다 내려간다

### 2.6 레포 밖에 있는 것 : ArgoCD 가 모르는 셋

`#14` 는 스크립트 0단계가 넣었다. ArgoCD 는 레포에 있는 것만 넣으므로 이 셋은 **여전히 누군가 넣어야** 한다

| 무엇 | `#14` | ArgoCD 가 넣으면 안 되는 이유 |
|---|---|---|
| Secret `monimo-db` · `monimo-tokens` | 스크립트가 로컬 기본값으로 | 레포가 공개다 (`AGENTS.md` §2). EKS 는 External Secrets(6단계) |
| ConfigMap `pg-migrations` · `ch-migrations` | 스크립트가 backend `db/` 를 읽어 | 스키마 파일을 이 레포에 두지 않는다 (`AGENTS.md` §2). EKS 는 이미지에 굽는다(5단계) |
| Secret `otlp-certs-collector` | 스크립트가 `otlp-certs` 이미지로 | 열쇠다 |

- ArgoCD 는 자기가 만들지 않은 자원을 **건드리지 않는다** : 이 셋이 있어도 prune 으로 지우지 않는다
- 다만 Job · 파드가 이 셋을 기다리므로, **ArgoCD sync 보다 먼저** 있어야 한다

### 출처

- 이 레포 `docs/plan.md` 3단계 · `#14` `research.md` · `scripts/up-local.sh` · `AGENTS.md`
- backend ADR `#62` H · `#66` ①②
- Argo CD 릴리스 (2026-10-19 GitHub API) : 안정판 `v3.5.5`(2026-10-12) · `v3.4.11`(2026-10-12) · `v3.3.16`, `v3.5.0` 은 2026-08-04
- 로컬 실측 2026-10-19 : `argocd` CLI `v3.4.2` 설치돼 있음 · Docker Desktop 메모리 약 25 GB · `kubectl v1.34.1`
- 2.2 ~ 2.5 의 ArgoCD 동작은 Argo CD 공식 문서(sync waves · resource hooks · sync options · app of apps) 기준으로 적었다. **2.4 의 Application 상태 판정은 3.x 에서 다시 확인한다**

---

## 3. 내가 물어본 것 (사람 차례)

<!-- 승조가 쓴다. 2절에서 모르겠는 것, 5절 선택지에 되물을 것 -->

> 2026-10-19 대화에서 승조가 물은 것을 Claude 가 모아 적었다 (답은 4절)

- 「지금과 달라지는 것」 표를 더 자세히 : 스크립트는 순서를 적어 둔 문서인가? sync wave 는 무엇이 다른가?
- ArgoCD 는 네임스페이스 하나에 파드 하나로 뜨나? 레포가 바뀌면 그걸 복사해서 넣나?
- hook Job 은 ArgoCD 가 쿠버네티스가 만든 Job 을 지우고 새로 만드는 것인가? Job 과 CronJob 의 관계는?
- Application 은 쿠버네티스 파일에 넣는 옵션인가? 매니페스트는 파일 하나에 전부 들어가나?
- 파드로 띄울 것은 전부 매니페스트를 쓰고 `kind` 에 따라 달라지나?
- Namespace 는 어떤 기준으로 나누나? ConfigMap · Secret 의 값은 어디로 가나? PVC 를 쓰면 PV 가 알아서 생기나?
- 레포 밖에 있는 것(Secret · ConfigMap)은 ArgoCD 와 어떻게 이어지나?
- App of Apps 는 Docker 멀티 스테이지 같은 것인가? 자식 목록을 적고 sync wave 로 순서대로 띄우는 방식인가?
- 5.5 · 5.6 의 트레이드오프를 쉽게

---

## 4. 1차 정리

- **스크립트도 레포에 있다** : 차이는 순서가 적힌 곳이 아니라 **누가 실행하나**다. `up-local.sh` 는 사람이 자기 컴퓨터에서 쳐야 순서가 지켜지고, sync wave 는 자원마다 붙은 번호표를 클러스터 안의 ArgoCD 가 읽어 지킨다 (처음 설명의 「순서가 스크립트가 아니라 레포에 있다」는 틀렸다)
- **ArgoCD 는 파드 일곱 개쯤**이다 (`repo-server` · `application-controller` · `server` · `redis` · `dex` · `applicationset` · `notifications`). 복사가 아니라 **비교해서 다른 것만** 넣는다
- **Job 은 ArgoCD 가 만들고 지우고, 쿠버네티스가 실행한다.** CronJob 은 사람 · ArgoCD 가 예약표만 넣고 Job 은 쿠버네티스가 만든다
- **Application 은 따로 된 매니페스트**(`kind: Application`)이고 폴더를 가리키기만 한다. 다른 파일 안에 붙는 ArgoCD 것은 번호표 · hook **주석**이다. 보통 자원 하나 = 파일 하나, `kustomization.yaml` 이 폴더 목차
- **매니페스트가 다 파드는 아니다** : Service · Namespace · ConfigMap · Secret · PVC · Application 은 파드가 아니다
- **Namespace 기준은 사람이 정한다** (우리는 역할별 `data` · `apm` · `shop`). 방을 나눠도 네트워크는 기본으로 통한다
- **Secret 은 base64 라 암호화가 아니다** : 클러스터 권한이 있으면 보인다. 값은 파드 안(환경변수 · 파일)으로만 들어가고 yaml 은 안 바뀐다
- **PVC 는 storageClass 가 있으면 PV 가 저절로 생긴다.** 없으면 `Pending`
- **레포에는 Secret · ConfigMap 의 이름만 있다** : 실제 값은 스크립트가 클러스터에 먼저 만들고, ArgoCD 가 넣은 파드가 켜질 때 찾아 쓴다. 없으면 `CreateContainerConfigError`
- **App of Apps 는 멀티 스테이지와 다르다** : 줄 세우기(앞 단계 버림)가 아니라 나무(부모 · 자식 전부 남음). root 는 목록이 아니라 **폴더**를 가리키고, 번호표는 **자식 Application 파일**에 붙는다

---

## 5. 선택지 정리

### 5.1 ArgoCD 를 어떻게 설치하나

| 갈래 | 장점 | 단점 |
|---|---|---|
| **ㄱ 공식 매니페스트 (`install.yaml`) 를 버전 고정해 `kubectl apply`** | 문서의 기본 길이다. 파일 하나 · 명령 하나. 우리 레포가 Helm 을 안 쓰는 것(`#14`)과 맞다 | 설정을 바꾸려면 `argocd-cm` 등을 따로 패치해야 한다 |
| **ㄴ 공식 Helm 차트 (`argo/argo-cd`)** | 설정을 values 하나에 모은다. EKS 에서 흔한 길 | 이 레포에 Helm 이 처음 들어온다 (`#14` 가 피한 것) |
| **ㄷ core 설치 (`core-install.yaml`)** | UI · API 서버 없이 가볍다 | **UI 가 없다.** 이번 목표(sync 결과 · 실패를 눈으로 읽기)와 안 맞는다 |

- 설치 매니페스트를 레포에 어떻게 둘지도 같이 정한다 : `argocd/install/kustomization.yaml` 이 GitHub 의 고정 버전 URL 을 가리키게 하면, 파일을 복사하지 않고 버전 한 줄로 관리된다
- 버전 : 안정판 `v3.5.5`(10/12) 와 한 줄 아래 `v3.4.11`(같은 날). 로컬 CLI 는 `v3.4.2`

### 5.2 Application 을 어떻게 나누나

| 갈래 | 장점 | 단점 |
|---|---|---|
| **ㄱ App of Apps : 묶음마다 Application 하나** (`0-namespaces` · `1-infra` · `2-jobs` · `3-apps`) | `overlays/local/` 모양 그대로. 연습 목표 「App of Apps」 를 그대로 밟는다. UI 에서 묶음별로 상태가 보인다 | Application 끼리 순서를 지키려면 2.4 의 상태 판정 설정이 필요하다 |
| **ㄴ Application 하나에 전부 + 자원마다 sync wave** | 순서가 한 Application 안에서 끝나 2.4 함정이 없다 | `overlays/local/` 를 하나로 묶는 kustomization 이 하나 더 생긴다. App of Apps 연습이 빠진다 |
| **ㄷ ApplicationSet** (폴더를 읽어 Application 을 찍어 낸다) | 폴더가 늘어도 손이 안 간다 | 묶음이 넷이라 과하다. 개념이 하나 더 는다 |

### 5.3 준비 Job 셋을 무엇으로 두나

| 갈래 | 장점 | 단점 |
|---|---|---|
| **ㄱ hook (`PreSync` 또는 `Sync`) + `BeforeHookCreation`** | sync 할 때마다 새로 돈다 = `up-local.sh` 의 「지우고 다시」와 같다. Job 이 내용을 못 고치는 문제가 없다. ADR `#66` ② 의 「훅」 그대로 | hook 은 UI 의 평소 자원 목록에서 빠져 「지금 상태」로 안 보인다. 마이그레이션이 매 sync 마다 돈다 (멱등이라 괜찮다 : Flyway · `--if-not-exists`) |
| **ㄴ 보통 자원 + sync wave 2 + `Replace=true`** | 늘 목록에 보인다. 바뀔 때만 다시 돈다 | 안 바뀌면 다시 안 돈다 : 저장소를 지우고 다시 만든 뒤에는 표가 없는데 Job 은 「이미 성공」으로 남는다 |
| **ㄷ 보통 자원 + `ttlSecondsAfterFinished`** | 쿠버네티스가 알아서 치운다 | 치우는 순간 ArgoCD 가 「없어졌다」로 OutOfSync 를 띄운다. 연습 중 헷갈린다 |

- 관통 확인 `telemetrygen` 도 같은 질문이다 : `PostSync` hook 으로 두면 「sync 가 끝날 때마다 관통 확인」이 된다

### 5.4 네임스페이스를 ArgoCD 가 관리하나

| 갈래 | 장점 | 단점 |
|---|---|---|
| **ㄱ 관리하되 `Prune=false`** | 레포에 네임스페이스가 그대로 남고, 실수로 지워도 저장소가 안 날아간다 | 네임스페이스를 정말 지우려면 손으로 |
| **ㄴ 관리하고 prune 도 허용** | 레포와 클러스터가 완전히 같다 | 2.5 의 함정 그대로 : 한 번의 prune 으로 데이터가 사라진다 |
| **ㄷ ArgoCD 가 안 만든다 (`CreateNamespace=true` 만)** | Application 이 필요할 때 만들어 준다 | 네임스페이스 이름표(`app.kubernetes.io/part-of`)가 안 붙는다. `namespaces/` 폴더가 쓸모없어진다 |

### 5.5 ArgoCD 가 어느 브랜치를 읽나 (고치고 확인하는 길)

| 갈래 | 장점 | 단점 |
|---|---|---|
| **ㄱ `develop`** | 머지된 것만 들어간다. EKS 와 같은 모양 | 이 이슈 작업 중에는 PR 을 머지해야 확인된다 |
| **ㄴ 작업 브랜치 (`feat/20-local-argocd`)** | push 만 하면 바로 확인된다. 연습에 맞다 | 끝나면 `develop` 으로 바꿔야 한다 (Application 의 `targetRevision` 한 줄) |
| **ㄷ 로컬 git 서버를 클러스터 안에 띄운다** | push 없이 된다 | 장치가 하나 는다. EKS 에서 안 쓸 길이다 |

- 로컬과 EKS 를 같은 모양으로 두려면 `targetRevision` 만 overlay 로 갈라 두는 길이 있다

### 5.6 `up-local.sh` 를 어떻게 하나

| 갈래 | 장점 | 단점 |
|---|---|---|
| **ㄱ 둘 다 남긴다** : `up-local.sh`(ArgoCD 없이 빠르게) · `up-argocd.sh`(설치 + 레포 밖 셋 + 뿌리 Application) | 데모 비상 대책(`AGENTS.md` §6)이 그대로 남는다. ArgoCD 가 막혀도 50초 길이 있다 | 순서가 두 군데(스크립트 · sync wave)에 적힌다 : 고칠 때 둘 다 |
| **ㄴ `up-local.sh` 를 ArgoCD 용으로 바꾼다** : 0단계(레포 밖 셋)만 남기고 1 ~ 3 은 sync 로 | 순서가 한 군데다 | ArgoCD 없이 띄우는 길이 사라진다 |
| **ㄷ 스크립트를 버리고 README 절차만** | 장치 0 | 레포 밖 셋을 손으로 넣어야 한다 (`#14` 5.5 에서 버린 길) |

---

## 6. 고르기 (사람 차례)

<!-- 승조가 고른다. 5.1 ~ 5.6 -->

2026-10-19 · 승조 정리본 (원문을 줄만 나눠 옮김) :

```
어떻게 구현할거냐?
공식 메니페스트 사용
Application은 App of Apps 방식으로 구현
root 파일을 만들어서 그 root가 가리키는 폴더 속 자식 파일을 실행하는데
그 자식 파일 안에 sync wave가 있어서 우선순위가 높은(숫자가 작은)것부터 실행한다
Job은 hook을 사용해서
네임스페이스 관리는 Prune 사용안하도록
혹시나 실수해서 날아가면 안되니까
ArgoCD가 읽는 브랜치는 ... 작업중엔 push 로만 PR 올릴 때는 develop
기존 up-local.sh 를 어떻게 할까... 그래서 둘 다 살리는 방향으로
```

- **5.1 : ㄱ 공식 매니페스트**
  - 버전은 안정판 `v3.5.x` 의 가장 최근 패치로 고정한다. `argocd/install/kustomization.yaml` 이 GitHub 의 그 버전 URL 을 가리키게 해서 파일 복사 없이 버전 한 줄로 관리
- **5.2 : ㄱ App of Apps (묶음마다 Application 하나)**
  - root 가 `argocd/apps/` 폴더를 가리키고, 그 폴더의 자식 Application 넷(`0-namespaces` · `1-infra` · `2-jobs` · `3-apps`)에 sync wave 를 붙여 묶음 순서를 지킨다
  - 2.4 함정 대비 : 순서가 안 지켜지면 `argocd-cm` 에 Application 상태 판정 설정을 넣고 그것도 레포에 둔다
- **5.3 : ㄱ hook**
  - 준비 Job 셋은 sync 마다 지우고 새로(`BeforeHookCreation`). 관통 확인 `telemetrygen` 은 `PostSync` hook
- **5.4 : ㄱ 관리하되 `Prune=false`** (승조 : 「혹시나 실수해서 날아가면 안되니까」)
- **5.5 : ㄴ 작업 중 → ㄱ 마지막** (승조 : 「작업중엔 push 로만 PR 올릴 때는 develop」)
  - 작업 중 : `targetRevision: feat/20-local-argocd` → push 만 하면 확인
  - PR 올릴 때 : `targetRevision: develop` 으로 한 줄 바꾸고 머지. 최종은 머지된 것만 들어가고 EKS 와 같은 모양
- **5.6 : ㄱ 둘 다 남긴다** (승조 : 「문제가 생기면 ArgoCD인지 메니페스트 인지 확인 가능 · ArgoCD 없이 띄울 수 있다」)
  - 레포 밖 셋 넣기(지금 `up-local.sh` 0단계)를 `scripts/local-prereqs.sh` 로 떼어 두 길이 같이 쓴다
  - `up-local.sh` : `local-prereqs` → `kubectl` 로 묶음 → 관통 확인 (ArgoCD 없이, 데모 비상 대책)
  - `up-argocd.sh` : ArgoCD 설치 → `local-prereqs` → root 넣기 (sync 는 사람이)
  - 남는 단점 : 묶음 순서가 두 곳(스크립트 차례 · sync wave)에 적힌다 → README 에 「순서를 바꾸면 둘 다 고친다」

---

## 7. 2차 정리

<!-- 6절 뒤에 쓴다 -->

---

## 8. 구현 프롬프트

<!-- 승조 차례. AI 가 쓰면 그 사실을 표시한다 -->

---

## 9. 프롬프트를 가지고 실제 구현

<!-- 구현 뒤에 쓴다 -->
