# monimo-deploy

설정 레포(GitOps 정답지): 쿠버네티스 매니페스트(생 YAML + kustomize overlay) · Argo CD Application · Phase 1a compose

- 기술: YAML · kustomize · Argo CD (Helm 은 쓰지 않는다 : `docs/plan.md` 「1단계 전에 정한 것」)
- 상태: 로컬 쿠버네티스에 수집 경로가 선다 (`#14`). 로컬 ArgoCD 로도 같은 것을 넣는다 (`#20`). EKS 는 `overlays/eks/` 에 자리만 있다

## 폴더 구성

| 폴더 | 하는 일 |
|---|---|
| `namespaces/` | 네임스페이스 `data` · `apm` · `shop` (`argocd` 는 ArgoCD 설치가 만든다) |
| `infra/` | 저장소 셋 StatefulSet(Kafka · ClickHouse · PostgreSQL) · 토픽 Job `kafka-init` |
| `schema/` | 마이그레이션 Job (`postgres-migrate` · `clickhouse-migrate`). **SQL 파일은 1a 동안 backend `db/` 에 둔다** |
| `apps/` | 서비스 Deployment. 폴더 하나 = 배포 단위 하나 (지금 `collector` · `ingester`) |
| `checks/` | 관통 확인 Job (`telemetrygen`) |
| `overlays/local/` · `overlays/eks/` | 넣는 곳. base(위 폴더들)를 가져와 환경마다 다른 것만 덮어쓴다. 묶음 `0-namespaces` → `1-infra` → `2-jobs` → `3-apps` 순서 |
| `scripts/` | `up-local.sh` : 묶음을 차례로 넣고 기다리고 관통까지 확인한다 · `up-argocd.sh` : 로컬 ArgoCD 를 띄우고 root 를 넣는다 · 둘이 같이 쓰는 `local-prereqs.sh`(레포 밖 준비물) · `check-local.sh`(관통 확인) · `lib.sh` |
| `argocd/` | `install/` ArgoCD 설치(공식 install.yaml 고정 버전) · `root.yaml` 뿌리 Application · `apps/local/` 자식 Application 셋 (App of Apps) |
| `charts/` | 비어 있다 (Helm 을 쓰게 되면 여기, `docs/plan.md` 되돌림) |
| `compose/` | Phase 1a 단일 노드 docker-compose |

## 로컬 실행 (Docker Desktop 쿠버네티스)

수집기 → Kafka → 적재 처리기 → ClickHouse 한 줄을 로컬 쿠버네티스에 올리고, 가짜 신호(`telemetrygen`)로 관통까지 확인한다.

**처음 한 번**

1. Docker Desktop 설정 → Kubernetes → 켜기 (`kubectl config current-context` 가 `docker-desktop`)
2. backend 레포를 이 레포 옆(`../monimo-backend`)에 두고 이미지를 만든다. 쿠버네티스는 이 로컬 이미지를 그대로 쓴다(레지스트리 없음)
   ```bash
   cd ../monimo-backend
   docker compose --profile collector --profile ingester build   # collector · ingester · clickhouse-migrate · otlp-certs
   ```

**올리기 · 지우기**

```bash
./scripts/up-local.sh          # 0 네임스페이스 · 비밀값 → 1 저장소 셋 → 2 준비 Job 셋 → 3 앱 둘 → 4 관통 확인
./scripts/up-local.sh --down   # 네임스페이스 셋을 지운다 (로컬 볼륨도 같이 지워진다)
```

- 쿠버네티스에는 compose 의 `depends_on` 이 없어서 넣은 것이 한꺼번에 뜬다. 스크립트가 묶음마다 `kubectl wait` 로 앞 묶음이 준비될 때까지 기다리고, 제한 시간(기본 300초)을 넘기면 그 자리에서 멈춘다
- 다시 쳐도 된다 : 매니페스트는 덮어쓰고 Job 은 지우고 새로 돌린다
- 비밀값 · 마이그레이션 SQL · 인증서는 레포에 없다. 스크립트가 넣는다
  - 계정 · 토큰 : backend `.env` 와 같은 이름의 환경변수, 없으면 로컬 기본값(`monimo` · `local-agent-token` …)
  - SQL : backend `db/postgres` · `db/clickhouse` 의 지금 작업 폴더를 ConfigMap 으로
  - 인증서 : backend `certs/` (compose 의 `otlp-certs` 와 같은 폴더, 없으면 만든다)
- backend 위치가 다르면 `BACKEND_DIR=/경로 ./scripts/up-local.sh`

**코드를 고친 뒤 (같은 `:dev` 태그 함정)**

같은 태그로 다시 빌드해도 떠 있는 파드는 안 바뀐다. 쿠버네티스 입장에서는 이미지 이름이 같기 때문이다 (compose 의 `--build` 함정과 같은 모양).

```bash
kubectl -n apm rollout restart deployment/collector
kubectl -n apm rollout restart deployment/ingester
```

**들여다보기**

```bash
kubectl -n data get pods,jobs,pvc
kubectl -n apm logs deploy/collector
kubectl -n apm port-forward svc/collector 4317:4317 18081:18081   # 내 컴퓨터에서 localhost:4317 · /actuator 로 닿기
```

**에이전트 mTLS 켜 보기** (로컬 실험, 커밋하지 않는다, `up-local.sh` 길) : 인증서 Secret 은 늘 들어가 있어서 수집기 환경변수 하나만 바꾸면 된다. base(`apps/`)는 EKS 와 같이 쓰므로 고치지 않는다

```bash
kubectl -n apm set env deployment/collector MONIMO_COLLECTOR_OTLP_GRPC_TLS_CLIENT_AUTH=optional
```

- `require` 로 올리면 평문으로 보내는 것이 전부 끊긴다 : `checks/telemetrygen` 과 **수집기 · 적재 처리기 자신의 에이전트**(자기 감시)
- 서버 인증서 이름은 `collector` · `localhost` 뿐이다 : 같은 `apm` 네임스페이스에서 `collector:4317` 로 부르면 맞고, 다른 네임스페이스에서 `collector.apm.svc.cluster.local` 로 부르면 이름 검사에서 끊긴다
- 되돌리기 : `./scripts/up-local.sh` 를 다시 치면 매니페스트 값(`none`)으로 돌아간다

**ArgoCD 로 올리기** (`#20`, 로컬 연습용 manual sync)

`up-local.sh` 는 내 컴퓨터의 파일을 `kubectl` 로 넣는다. 이 길은 **GitHub 에 push 된 것**을 ArgoCD 가 읽어 넣는다. 같은 클러스터에 둘을 섞지 않는다 : 하나로 올렸으면 그 `--down` 으로 지우고 다른 길로 올린다

```bash
./scripts/up-argocd.sh          # ArgoCD 설치 → 레포 밖 준비물(local-prereqs.sh) → root 넣기 → 들어가는 법 출력
kubectl -n argocd port-forward svc/argocd-server 8080:443        # https://localhost:8080
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d   # admin 비밀번호
argocd app sync root            # 또는 UI 에서 root → Sync
argocd app list                 # 넷 다 Synced · Healthy (빈 클러스터에서 약 40초)
./scripts/check-local.sh        # 관통 확인
./scripts/up-argocd.sh --down   # argocd · apm · data · shop 을 지운다
```

- **사람이 누르는 것은 root 하나다** : root 는 manual, 자식 셋(`local-namespaces` · `local-infra` · `local-apps`)은 automated(prune · selfHeal 끔)
  - root 를 Sync 해야 자식이 생기거나 자식 파일(`argocd/apps/local/`)의 변경이 들어간다
  - 이미 있는 자식은 push 하면 스스로 따라간다 (ArgoCD 가 레포를 3분마다 본다. 바로 보려면 `argocd app get <이름> --refresh`)
  - 자식까지 manual 이면 root sync 가 자식마다 멈춰 선다 : root 는 앞 번호 자식이 Healthy 가 돼야 다음으로 가는데 manual 자식은 누르기 전엔 Healthy 가 안 된다
- 준비 Job 셋은 `local-apps` 의 **PreSync hook** 이다 : 앱을 넣기 직전에 새로 돌고 셋 다 성공해야 앱이 들어간다. `local-apps` 가 sync 할 때마다(수집기 값 하나를 바꿔도) 다시 돈다
- 레포를 읽는 브랜치는 `develop` 이다 (`targetRevision` 다섯 줄 : root 하나 · 자식 셋, `local-apps` 는 source 가 둘). 브랜치에서 고친 것을 보려면 그 다섯 줄을 브랜치 이름으로 바꿔 push 하고, PR 전에 되돌린다
- 비밀값 · SQL · 인증서는 ArgoCD 가 모른다 (레포에 없다). `up-argocd.sh` 가 `local-prereqs.sh` 로 먼저 넣는다. SQL 을 고쳤으면 `./scripts/local-prereqs.sh` 를 다시 치고 `argocd app sync local-apps`
- **순서는 두 곳에 적혀 있다** : `up-local.sh`(묶음을 넣는 차례)와 `argocd/apps/local/*.yaml`(sync wave 번호표). **순서를 바꾸면 둘 다 고친다**
- `checks/telemetrygen` 은 ArgoCD 에 넣지 않는다 : 「보내기 전 줄 수 → 보내기 → 늘었나」를 한 흐름으로 봐야 해서 `check-local.sh` 가 한다

**스크립트 설정** (환경변수, 전부 기본값이 있다)

| 이름 | 기본값 | 하는 일 |
|---|---|---|
| `BACKEND_DIR` | `../monimo-backend` | SQL · 인증서를 읽을 backend 작업 폴더 |
| `KUBE_CONTEXT` | `docker-desktop` | 넣을 클러스터 |
| `ALLOW_OTHER_CONTEXT` | (비어 있음) | `1` 이면 docker-desktop 아닌 곳에도 올린다. `--down` 은 이 값과 상관없이 docker-desktop 에서만 된다 |
| `WAIT_SECONDS` | `300` | 묶음마다 기다리는 제한 시간(초) |
| `CHECK_WAIT_SECONDS` | `60` | 관통 확인에서 ClickHouse 에 줄이 생기기를 기다리는 시간(초) |
| `POSTGRES_USER` · `POSTGRES_PASSWORD` · `CLICKHOUSE_USER` · `CLICKHOUSE_PASSWORD` | `monimo` | 저장소 계정 (backend compose 와 같은 로컬 기본값). 바꾸면 `--down` 뒤에 올린다 : PG 볼륨은 처음 비밀번호를 기억한다 |
| `MONIMO_AGENT_TOKEN` · `MONIMO_INTERNAL_TOKEN` | `local-agent-token` · `local-internal-token` | 스레드 덤프 명령 문 토큰 |

## 환경변수

실제 값은 레포에 올리지 않는다. `.env.example` 에 이름만 적는다.

Phase 1a compose(`compose/`)용 (`.env.example` 참고). 1b 이후 EKS 비밀값은 AWS Secrets Manager 에 두고 values 에는 이름만 적는다.

| 이름 | 설명 |
|---|---|
| `IMAGE_REGISTRY` · `IMAGE_TAG` | 띄울 이미지 주소 · 태그 (CI 봇이 갱신하는 `image.tag` 와 같은 값) |
| `CLICKHOUSE_USER` · `CLICKHOUSE_PASSWORD` | ClickHouse 계정 |
| `POSTGRES_USER` · `POSTGRES_PASSWORD` | PostgreSQL 계정 |
| `MYSQL_USER` · `MYSQL_PASSWORD` | 쇼핑몰 MySQL 계정 |

## 포트

클러스터 안 주소다. 내 컴퓨터에서는 `kubectl port-forward` 로 연다.

| 서비스 | 주소 | 포트 |
|---|---|---|
| 수집기 | `collector.apm.svc.cluster.local` | 4317 OTLP gRPC · 8081 업무(`/livez` · `/readyz`) · 18081 관리(`/actuator`) |
| 적재 처리기 | `ingester.apm.svc.cluster.local` | 8082 업무 · 18082 관리 |
| Kafka | `kafka-0.kafka.data.svc.cluster.local` | 29092 |
| ClickHouse | `clickhouse.data.svc.cluster.local` | 8123 HTTP · 9000 native |
| PostgreSQL | `postgres.data.svc.cluster.local` | 5432 |

## 관련 문서

- 1b 배포 순서와 다음 할 일 : [`docs/plan.md`](docs/plan.md)

- [설계 문서 (결정 기록 원본)](https://github.com/2026-techeer-project-team-b/monimo-backend/tree/HEAD/docs/design): monimo-backend 레포의 `docs/design/`
- [레포별 파일 구성](https://app.notion.com/p/3e1d7d6851ff80a8a110e8aea0b5783b)
- [깃허브 레포지토리 규칙](https://app.notion.com/p/3dcd7d6851ff8000b795f1cc609124e6)

## 기여 규칙

- 브랜치 전략: 기능 브랜치 → `develop`(기본 브랜치, 작업을 모으는 곳) → 배포 단위로 `develop` → `main`
- `main` · `develop` 직접 push 금지, PR로만 머지. PR 의 base 는 기본값(`develop`) 그대로 두면 된다
- 브랜치: `feat/<이슈번호>-<설명>` · `fix/<이슈번호>-<설명>` · `chore/<설명>`
- 커밋: `<타입>(<범위>): <요약>` (타입: feat · fix · docs · chore · refactor · test)

## AI 와 일한 방법 (승조 담당)

이 레포는 승조(`@SeungJo-02`) 담당이고 AI(Claude Code)와 함께 만들었다. 규칙은 [`AGENTS.md`](AGENTS.md), 절차 · 역할 분담 · 토큰 기준값 · AI 가 틀린 것과 잡은 방법은 `monimo-backend` 의 [`docs/seungjo/harness.md`](https://github.com/2026-techeer-project-team-b/monimo-backend/blob/HEAD/docs/seungjo/harness.md)(정본, 한 곳에만 둔다), 이 레포에서 무엇을 어떻게 물었는지는 [`docs/prompts/`](docs/prompts/README.md) 에 있다.
