# AGENTS.md — 작업을 시작하기 전에 읽는 파일

> **사람이든 AI 도구든, 이 레포에서 무언가를 고치기 전에 이 파일을 먼저 읽는다.**
> 여기에는 레포 구조, 깨면 안 되는 규칙, 지금까지 한 일, 지금 막혀 있는 것이 들어 있다.
>
> 작업을 끝내면 **§5(지금까지 한 일)와 §6(막혀 있는 것)을 갱신해서 같은 PR 에 넣는다.**

## 0. 정본이 어디인가

| 무엇 | 정본 |
|---|---|
| 설계 결정(ADR) | `monimo-backend` 레포 `docs/design/01-decisions.md` |
| 1b 배포 순서 · 다음 할 일 | 이 레포 `docs/plan.md` |
| 환경변수 이름 | 이 레포 `README.md` 와 `.env.example` |
| PG 마이그레이션 · ClickHouse DDL | Phase 1a 동안은 `monimo-backend` 의 `db/` (1b 부터 이 레포 `schema/`, ADR `#49`) |

## 1. 레포 한눈에

설정 레포다. 여기 적힌 내용이 "클러스터가 이래야 한다"는 정답지이고, Argo CD 가 클러스터를 이 레포에 맞춘다 (GitOps). 애플리케이션 코드는 없다.

생 YAML + kustomize overlay · Argo CD. Helm 은 쓰지 않는다 (`docs/plan.md` 「1단계 전에 정한 것」, 2026-10-16 : 다섯 번 복사가 손에 걸리면 공통 차트로 올린다).

위 폴더들이 **base**(로컬과 EKS 에 똑같은 것)이고, 클러스터에 넣는 곳은 `overlays/` 다. overlay 가 base 를 가져와 환경마다 다른 것(이미지 줄 · 볼륨 크기 · 노드)만 덮어쓴다.

| 폴더 | 하는 일 |
|---|---|
| `namespaces/` | `data` · `apm` · `shop` (`argocd` 는 ArgoCD 설치가 만든다). `Prune=false` : ArgoCD 가 지우지 않는다 |
| `infra/` | 저장소 셋 StatefulSet + Headless Service (Kafka · ClickHouse · PostgreSQL) · 토픽 Job `kafka-init` |
| `schema/` | 마이그레이션 Job (`postgres-migrate` · `clickhouse-migrate`). SQL 파일은 두지 않는다 (§2) |
| `apps/` | 서비스 Deployment + Service. **폴더 하나 = 배포 단위 하나** |
| `checks/` | 관통 확인 Job (`telemetrygen`) |
| `overlays/local/` · `overlays/eks/` | 넣는 곳. 묶음 `0-namespaces` → `1-infra` → `2-jobs` → `3-apps` (→ `4-checks`) 순서로 넣는다 |
| `scripts/` | 로컬 전용. `up-local.sh` : 묶음을 차례로 넣고 `kubectl wait` 로 기다린다 · `up-argocd.sh` : 로컬 ArgoCD 를 띄우고 root 를 넣는다 · 둘이 같이 쓰는 `local-prereqs.sh`(레포 밖 준비물 : Secret · SQL · 인증서) · `check-local.sh`(관통 확인) · `lib.sh` |
| `argocd/` | `install/` : 공식 install.yaml 고정 버전(`v3.5.5`) + Application 상태 판정 패치 · `root.yaml` : 뿌리(manual) · `apps/local/` : 자식 셋(automated, prune · selfHeal 끔), sync wave 0 · 1 · 3. 준비 Job 셋은 `local-apps` 의 PreSync hook |
| `charts/` | 비어 있다 (Helm 으로 옮기게 되면) |
| `compose/` | Phase 1a 단일 노드 docker-compose |

## 2. 깨면 안 되는 규칙

- **비밀값은 레포에 올리지 않는다.** 레포는 퍼블릭이다. compose 는 `.env.example` 에 이름만, 1b 이후 EKS 비밀값은 AWS Secrets Manager 에 두고 매니페스트에는 Secret 이름만 적는다. 로컬은 `scripts/local-prereqs.sh` 가 Secret 을 넣는다.
- **`image.tag` 는 CI 봇이 갱신하는 값이다.** 손으로 바꿀 때는 PR 설명에 이유를 적는다.
- **`apps/` 는 폴더 하나가 배포 단위 하나다.** 한 폴더에 서비스 두 개의 매니페스트를 섞지 않는다.
- **클러스터를 직접 고치지 않는다.** 바꿀 것은 이 레포에 PR 로 올린다. 직접 고친 내용은 Argo CD 가 되돌리거나, 레포와 어긋난 채 남는다.
- **스키마 파일은 1a 동안 여기 두지 않는다.** 같은 파일이 두 레포에 있으면 어느 쪽이 맞는지 알 수 없다. 로컬은 `local-prereqs.sh` 가 backend `db/` 를 ConfigMap 으로 넣고, EKS 는 5단계에서 마이그레이션 이미지에 굽는다.

## 3. 작업 흐름

1. GitHub 이슈를 만든다. 제목은 커밋 형식과 같게.
2. 브랜치를 판다. `feat/<이슈번호>-<설명>` · `fix/<이슈번호>-<설명>` · `chore/<설명>`. **`origin/develop` 에서 새로 판다.**
3. 커밋 메시지는 `<타입>(<범위>): <요약>`. 타입은 feat · fix · docs · chore · refactor · test.
4. PR 의 base 는 `develop`. `main` · `develop` 직접 push 는 막혀 있다.

## 4. 담당

승조 `@SeungJo-02` 단독.

## 5. 지금까지 한 일

- 레포 초기 구성, PR 라벨 자동화와 머지 슬랙 알림 (`#1`)
- `.env.example` — Phase 1a compose 용 이미지 · 인프라 계정 이름 (`#2`)
- CODEOWNERS (`#3`), develop 브랜치 전략 (`#4`), 설계 문서 링크를 `tree/HEAD` 로 (`#5`)
- `AGENTS.md` · `CLAUDE.md`, README 「AI 와 일한 방법」 절, `docs/prompts/`(프롬프트 로그 : 코드와 같은 PR 에). 하네스 정본은 backend `docs/seungjo/harness.md` 한 곳
- `#62` ⑤ 부분 개정 (`#11`, backend `#159` 에이전트 mTLS · ADR `#64`) : 입구(Traefik + NLB)에서 수집기 gRPC 통로를 뺀다. 바깥 에이전트는 안 받고 TLS 는 수집기가 직접 끝낸다(mTLS). 문서만. `docs/seungjo/9-eks-foundation/` README 표 E 행 · research 2.6
- 로컬 ArgoCD (`#20`, `docs/plan.md` 3단계). 공식 install.yaml `v3.5.5` 고정 · App of Apps(root manual · 자식 셋 automated, prune · selfHeal 끔) · sync wave · 준비 Job 셋은 `local-apps` 의 PreSync hook · 네임스페이스 `Prune=false` · Application 상태 판정(`argocd-cm`). 스크립트를 `local-prereqs.sh` · `check-local.sh` · `lib.sh` 로 나눠 `up-local.sh` 와 `up-argocd.sh` 가 같이 쓴다. 실측 · 연습 결과는 `docs/seungjo/20-local-argocd/research.md` 9절
- 로컬 쿠버네티스에 수집 경로 (`#14`, `docs/plan.md` 1단계). 생 YAML + kustomize overlay · 저장소 셋 StatefulSet(공식 이미지) · 준비 Job 셋 · 수집기 · 적재 처리기 · `telemetrygen` 관통 확인을 `scripts/up-local.sh` 하나로. 이미지는 로컬 빌드 태그 + `IfNotPresent`. SQL · 인증서 · 비밀값은 레포 밖(스크립트가 넣는다). `overlays/eks/` 는 자리만. `docs/seungjo/14-local-k8s-collect/research.md`
- 1b EKS 배포 기반 결정 (`#9`, backend ADR `#62`). 서울 · 데이터 온디맨드 t3.large 1대(한 AZ) + 앱 Spot t3.large 2대 · 정해진 시간만 켬(발표 전 상시) · NAT 인스턴스(fck-nat) · Traefik + NLB · 공식 이미지 StatefulSet + EBS(Retain) · External Secrets · CI 가 GitHub App 토큰으로 `image.tag` 커밋 · 관리형 노드 그룹 고정. 월 약 $167 ~ 220. `docs/seungjo/9-eks-foundation/`

## 6. 지금 막혀 있는 것

| 무엇 | 안 풀면 |
|---|---|
| **~~폴더 7개가 전부 비어 있다~~ (`#14` 로 해소 : `namespaces` · `infra` · `schema` · `apps` 가 찼다. `argocd` 는 `#20`. `charts` · `compose` 는 아직)** | 로컬 쿠버네티스에는 수집 경로가 선다. EKS 값(`overlays/eks/`)은 자리만 있다 |
| `compose/` 단일 노드 compose 가 없다 | Phase 1a 를 한 서버에 올릴 방법이 없다 |
| 로컬 쿠버네티스에 올라간 것은 수집 경로뿐이다 (쇼핑몰 · api-server · detector · notifier 없음) | 화면 · 경보까지의 관통은 아직 compose 로만 된다. `telemetrygen` 으로는 서버맵 · 파드 이름표를 못 본다 |
| 마이그레이션 SQL 이 EKS 로 갈 길이 없다 | 로컬은 스크립트가 backend `db/` 를 ConfigMap 으로 넣지만 EKS 에는 그 폴더가 없다. 5단계(CI → ECR)에서 마이그레이션 이미지에 SQL 을 굽는다 (backend 쪽 Dockerfile) |
| AWS 계정 · 결제 · 예산 알림, 도메인이 없다 (~~GitHub App~~ 은 2026-10-16 준비됨) | Terraform apply(`#17`) · cert-manager 인증서가 막힌다 |
| 발표가 11월 4주로 밀렸다 (날짜 정본 `docs/plan.md`) | Terraform 이 이틀 넘게 막히면 eksctl 로 내린다. EKS 가 끝내 안 되면 로컬 k8s 로 데모를 찍는다 (`scripts/up-local.sh` · `up-argocd.sh` 가 그 바닥이다) |
| ArgoCD 는 로컬에만 있다 (`overlays/eks/` · `argocd/apps/eks/` 없음) | 6단계에서 EKS 자식 Application 과 자동 sync 를 새로 적는다. 레포 밖 준비물(Secret · SQL)은 로컬은 스크립트, EKS 는 External Secrets · 마이그레이션 이미지로 바꿔야 ArgoCD 혼자 선다 |

## 7. 참고

- 설계 문서: https://github.com/2026-techeer-project-team-b/monimo-backend/tree/HEAD/docs/design
- 이미지를 만드는 쪽: `monimo-backend` · `monimo-shop` 의 CI
