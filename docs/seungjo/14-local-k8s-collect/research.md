# `#14` 로컬 쿠버네티스에 수집 경로를 올린다

이슈 `#14` · 2026-10-14 · 승조(`@SeungJo-02`)

9단계 틀로 쓴다. 3 · 6 절은 승조 차례(질문과 선택)이고 8절은 구현 프롬프트다.

> `#9` 가 EKS 의 **모양**을 정했고(리전 · 노드 · 네트워크 · 입구 · 데이터 · 비밀값 · 이미지 태그), `#184`(backend ADR `#66`)가 **순서와 인증서**를 정했다. 이번은 그 결정들을 **처음으로 파일로 옮기는** 일이다. 레포 폴더 일곱 개가 아직 전부 `.gitkeep` 만 있다.

---

## 1. 무엇을 하려는 것인가

로컬 쿠버네티스에 **수집 경로를 통째로** 올린다. compose 로 되는 것을 쿠버네티스로 한 번 옮겨 보는 것이고, 옮기는 과정에서 매니페스트 · 차트의 모양이 정해진다.

### 왜 EKS 보다 먼저인가

| 이유 | 근거 |
|---|---|
| 일정이 그렇게 잡혀 있다 | `#9` README 「다음」 : 10/18~21 로컬 쿠버네티스, Terraform 첫 `apply` 는 10/22~23 |
| **데모 비상 대책이다** | `AGENTS.md` §6 : EKS 가 끝내 안 되면 로컬 쿠버네티스로 데모를 찍는다 (10/24 까지 로컬 전체 관통) |
| 매니페스트가 틀렸는지를 돈 안 들이고 안다 | EKS 는 고정비가 예산의 절반이라(`#9`) 켜 둔 채로 고치면 비싸다 |

### 지금 무엇이 없나

| 폴더 | 들어갈 것 | 지금 |
|---|---|---|
| `namespaces/` | `apm` · `data` · `shop` · `argocd` | `.gitkeep` |
| `infra/` | Kafka · ClickHouse · PostgreSQL | `.gitkeep` |
| `schema/` | PG 마이그레이션 · ClickHouse DDL (1b 부터 이쪽, ADR `#49`) | `.gitkeep` |
| `charts/` | 공통 차트 (서비스용 · 쇼핑몰용) | `.gitkeep` |
| `apps/` | 서비스별 values. 폴더 하나 = 배포 단위 하나 | `.gitkeep` |
| `argocd/` | AppProject · Application | `.gitkeep` |
| `compose/` | Phase 1a 단일 노드 compose | `.gitkeep` |

이번 이슈에서 손대는 것은 위의 다섯(`namespaces` · `infra` · `schema` · `charts` · `apps`)이다. `argocd/` 는 배포 도구가 서는 10/25~27 몫이고 `compose/` 는 1a 몫이다.

### 이미 정해져 있는 것 (다시 정하지 않는다)

| 무엇 | 어디서 |
|---|---|
| 순서 장치는 **손으로 시작**하고 배포 도구가 서면 훅으로 옮긴다. Job 정의는 compose 의 일회성 컨테이너 모양 그대로 둔다 | ADR `#66` ①② |
| 인증서는 **두 묶음**(수집기용 · 쇼핑몰용). 금고에 두고 External Secrets 가 꺼내 파드에 **파일로** 건다. 요구 수준은 금고 밖 | ADR `#66` ③⑤, `#62` ⑦ |
| 저장소는 **공식 이미지 StatefulSet**, 볼륨은 `Retain` | ADR `#62` |
| 관리 포트는 업무 포트 + 10000. `readiness` 는 저장소를 안 본다 | ADR `#58` |
| ClickHouse PVC 출발값 **50 GB** | backend `20-scope.md` 「PVC 크기 근거」 |
| 파드 이름표(`service.instance.id`)는 파드 이름 그대로, Downward API | monimo-shop `#30` |
| 비밀값은 레포에 올리지 않는다. 레포 다섯 개가 전부 공개다 | `AGENTS.md` §2 |

---

## 2. 꼭 알아야 하는 것 다섯

### 2.1 compose 의 표시등이 쿠버네티스에는 없다

compose 는 `infra-ready` 하나로 순서를 지킨다. 일회성 서비스 넷이 **성공 종료**해야 그 표시등이 켜지고, 앱은 그 표시등을 기다린다.

```
kafka-init           토픽 raw(파티션 3 · 7일) · raw.dlq(파티션 1 · 30일) 만들기
postgres-migrate     Flyway
clickhouse-migrate   Flyway + 커뮤니티 플러그인
otlp-certs           인증서 생성
       ↓ 넷 다 성공 종료
infra-ready (표시등)
       ↓
collector · ingester
```

쿠버네티스에는 `depends_on: service_completed_successfully` 가 없다. 순서가 틀리면 걸리는 자리가 셋이다 (ADR `#66` 근거)

| 자리 | 순서가 틀리면 |
|---|---|
| 표와 코드가 다름 (`ddl-auto: validate`, 다섯 모듈 전부) | **앱이 기동 실패**한다 |
| 토픽 없음 (`KAFKA_AUTO_CREATE_TOPICS_ENABLE: "false"`) | 수집기는 뜨지만 **발행이 실패**한다. 에이전트에 `UNAVAILABLE` 로 돌려보내므로 유실은 아니고 수집이 안 되는 상태다 |
| 요구 수준을 켠 뒤 인증서를 못 읽음 | **수집기가 기동 실패**한다 (ADR `#64` ⑨, 평문으로 대신 뜨지 않는다) |

쿠버네티스는 죽은 파드를 계속 다시 띄우니 **결국은 뜬다.** 장치의 값은 "결국 뜨는가" 가 아니라 ① 배포 성공을 착각하지 않는 것 ② 재시작 루프 동안 에이전트 버퍼를 낭비하지 않는 것 ③ 사람이 원인을 빨리 아는 것이다 (ADR `#66` 채택 사유).

### 2.2 저장소 셋과 앱 둘은 쿠버네티스에서 성질이 다르다

| | 저장소 셋 (Kafka · ClickHouse · PostgreSQL) | 앱 둘 (수집기 · 적재 처리기) |
|---|---|---|
| 자원 | StatefulSet + PVC + Headless Service | Deployment + Service |
| 이름 | `kafka-0` 처럼 번호가 붙고 재시작해도 같다 | 재시작하면 이름이 바뀐다 |
| 볼륨 | `volumeClaimTemplates`. EKS 는 EBS `Retain`(ADR `#62`) | 없다 |
| 노드 | EKS 는 온디맨드 한 AZ 고정 (ADR `#62`) | EKS 는 Spot 2대 |
| 지우면 | PVC 가 남는다. StatefulSet 을 지워도 볼륨은 안 지워진다 | 아무것도 안 남는다 |

로컬에서 바뀌는 것은 **볼륨 종류 하나**다. EBS 가 없으니 기본 `storageClass`(Docker Desktop 은 `hostpath`)를 쓴다. 신청 크기 50 GB 는 **`overlays/local` 에서 작게 덮어쓴다** (2026-10-17 고침 : 처음엔 「로컬 values」라고 썼는데 Helm 말이다. 5.2 가 kustomize 로 정해졌다).

- `hostpath` 는 Docker Desktop 안의 폴더 하나라 **50 GB 를 미리 차지하지 않고, 넘어도 막지 않을 가능성이 크다** (2026-10-17 고침 : 처음엔 「그만큼 잡는다」고 썼다). 구현 때 PVC 하나로 확인해서 9절에 적는다. 그래도 신청 숫자는 실제 쓰는 양에 맞춰 둔다
- 회수 정책도 갈린다 : 동적으로 만든 볼륨은 storageClass 의 `reclaimPolicy` 를 따르고 기본은 대개 `Delete` 다. EKS 의 `Retain`(ADR `#62`)은 EBS storageClass 에 적는다. 로컬은 구현 때 `hostpath` 의 값을 확인해 적는다

### 2.3 로컬에서 이미지를 어떻게 먹이나가 EKS 와 가장 다른 점이다

EKS 는 CI 가 ECR 에 올리고 봇이 `image.tag` 를 이 레포에 커밋한다(ADR `#62`). 로컬에는 ECR 도 CI 도 없다.

- 지금 로컬에 있는 것 : `monimo/collector:dev` · `monimo/ingester:dev`(backend `#170` Dockerfile 하나 · 멀티스테이지 · `target`)
- 지금 도커 상태 : Docker Desktop `29.2.1`, 이미지 저장소가 **containerd**(`io.containerd.snapshotter.v1`)
- Docker Desktop 쿠버네티스는 **Docker 엔진을 통해 컨테이너를 띄우므로** 로컬에서 만든 태그를 레지스트리 없이 쓸 수 있다 (2026-10-17 고침 : 처음엔 「같은 containerd 를 쓰므로」라고 썼는데, 시험 파드의 컨테이너 번호가 `docker://...` 로 찍혀 Docker 엔진을 거친다는 것이 보였다)
- `imagePullPolicy` 가 `Always` 면 쿠버네티스가 이미지 이름의 창고(`monimo/collector` 는 창고 주소가 없어 Docker Hub)에서 당기려 하고 **없는 이미지라 `ErrImagePull` 로 멈춘다**
  - 칸을 비우면 태그로 기본값이 정해진다 : `latest` 거나 태그가 없으면 `Always`, 그 밖(`:dev` 같은)은 `IfNotPresent`. 그래서 `:dev` 는 비워도 돈다 (2026-10-17 고침 : 처음엔 「안 두면 멈춘다」고 썼다)
  - 그래도 **명시해서 적는다** : 태그가 `latest` 로 바뀌는 순간 조용히 `Always` 가 되어 깨지기 때문
- **확인함 (2026-10-17)** : 시험 네임스페이스에 `monimo/collector:dev` · `imagePullPolicy: IfNotPresent` 파드 하나를 띄웠더니 kubelet 이 `Container image "monimo/collector:dev" already present on machine` 을 남기고 성공 종료했다. **로컬 레지스트리 없이 된다.** 시험 네임스페이스는 지웠다

### 2.4 레포 구조가 이미 "차트 + values" 를 전제한다

`AGENTS.md` §1 이 `charts/` 를 "공통 차트(서비스용 · 쇼핑몰용)", `apps/` 를 "서비스별 values, **폴더 하나 = 배포 단위 하나**" 로 적어 뒀고, §2 가 "한 폴더에 서비스 두 개의 values 를 섞지 않는다" 를 깨면 안 되는 규칙으로 뒀다.

즉 생 YAML 로 시작하더라도 **끝 모양은 차트 + values** 다. 고를 것은 "지금부터 차트로 쓸지, 생 YAML 로 한 번 돌려 보고 차트로 접을지" 라는 순서뿐이다.

> **2026-10-17 고침** : 위 두 문단은 10/14 기준이다. 10/16 `docs/plan.md` 가 **생 YAML + kustomize overlay** 로 정해(5.2) 「끝 모양은 차트 + values」는 더 이상 맞지 않는다. 이 PR 에서 `AGENTS.md` §1 표를 `base` · `overlays` 모양으로 고친다. 「폴더 하나 = 배포 단위 하나」는 `base/` 안에서 서비스마다 폴더를 나눠 그대로 지킨다

도구 상태 : `kubectl v1.34.1` · `helm v4.2.0` 설치돼 있다. `kind` · `minikube` 는 없다. 컨텍스트 `docker-desktop` 은 있는데 **클러스터가 꺼져 있다**(`127.0.0.1:6443` 연결 거부). → 2026-10-17 에는 켜져 있다 : 노드 `docker-desktop` 하나 `Ready` · `v1.34.1`

### 2.5 관통을 확인하려면 신호를 흘리는 쪽이 필요하다

수집기 · 적재 처리기만 올리면 "떴다" 까지만 알 수 있다. compose 의 `check-pipeline.sh` 가 하는 일(신호를 넣고 ClickHouse 에서 센다)을 쿠버네티스에서도 해야 하는데, 넣는 쪽 후보가 셋이다

| 넣는 쪽 | 무엇을 확인할 수 있나 | 비용 |
|---|---|---|
| 쇼핑몰 넷을 쿠버네티스에 같이 | **진짜 실데이터.** 파드 이름표 · mTLS · 서버맵까지 | 쇼핑몰 차트 · MySQL · Redis · 게이트웨이까지 올려야 한다 |
| 쇼핑몰은 compose 에 두고 수집기만 쿠버네티스 | 실데이터이긴 하다 | compose 쪽에서 클러스터 안 4317 로 닿는 길을 열어야 한다(`NodePort` 등) |
| `telemetrygen` Job | 경로가 뚫렸는지만 | 가장 싸다. 꼬리표 모양이 실데이터와 다르다(ADR `#65` ⑥) |

### 출처

- 이 레포 `AGENTS.md`(§1 폴더 · §2 규칙 · §6 막힌 것) · `docs/seungjo/9-eks-foundation/README.md`(결정 표 · 「다음」 일정)
- backend `docs/design/01-decisions.md` ADR `#49` `#57` `#58` `#62` `#64` `#65` `#66` · `docs/design/20-scope.md`(PVC 크기 근거)
- backend `compose.yaml`(서비스 11개 · `infra-ready` · `kafka-init` 토픽 둘) · `scripts/check-pipeline.sh`
- 로컬 실측 2026-10-14 : `docker version` `29.2.1` · `docker info`(containerd 이미지 저장소) · `kubectl v1.34.1` · `helm v4.2.0` · `kubectl get nodes` 연결 거부

---

## 3. 내가 물어본 것 (사람 차례)

<!-- 승조가 쓴다. 2절에서 모르겠는 것, 5절 선택지에 되물을 것 -->

---

## 4. 1차 정리

<!-- 3절 뒤에 쓴다 -->

---

## 5. 선택지 정리

> **2026-10-16 에 `docs/plan.md` 가 셋을 먼저 정했다** (이 절을 쓴 10/14 뒤)
> - 5.1 : **ㄱ Docker Desktop** (일정표가 적어 둔 대로, 2026-10-17 켜져 있다)
> - 5.2 : **생 YAML + kustomize overlay** (ㄱ 과 ㄷ 을 합친 모양 : `base` 는 생 YAML, `overlays/local` · `overlays/eks` 가 이미지 줄을 갈아끼운다). 아래 ㄷ 의 단점 「레포가 Helm 을 적어 뒀다」는 `AGENTS.md` §1 표를 이 PR 에서 고쳐 푼다
> - 5.3 : **ㄱ 로컬 태그 + `IfNotPresent`** (`Never` 가 아니다. 이유는 `plan.md`). 2.3 에서 실제로 되는 것을 확인했다
>
> 남은 것은 5.4 · 5.5 · 5.6 이다

### 5.1 로컬 클러스터를 무엇으로 하나

| 갈래 | 장점 | 단점 |
|---|---|---|
| **ㄱ Docker Desktop** | 이미 설치돼 있고 컨텍스트도 있다. 켜기만 하면 된다. 로컬 이미지를 그대로 쓸 가능성이 가장 높다(2.3) | 노드가 한 개라 노드 분리(ADR `#62` 의 데이터 온디맨드 · 앱 Spot)를 흉내 낼 수 없다. 자원을 많이 먹는다 |
| **ㄴ kind** | 노드를 여러 개 만들 수 있어 `nodeSelector` · `taint` 를 실제로 시험할 수 있다. 버리고 다시 만들기가 빠르다 | 설치해야 한다. 로컬 이미지를 `kind load docker-image` 로 **넣어 줘야** 한다(한 단계 늘어난다) |
| **ㄷ minikube** | 드라이버를 고를 수 있다 | 설치해야 하고 Docker Desktop 과 자원을 다툰다. kind 보다 무겁다 |

고려 : EKS 에서 쓸 `nodeSelector` 를 로컬에서 **시험만 하고 싶은지** 아니면 **일단 뜨는 것만 보고 싶은지**로 갈린다. 일정표는 10/18~21 에 Docker Desktop 을 적어 뒀다.

### 5.2 매니페스트 모양

| 갈래 | 장점 | 단점 |
|---|---|---|
| **ㄱ 생 YAML 로 먼저, 뒤에 차트로 접는다** | 가장 빨리 돈다. 무엇이 틀렸는지가 YAML 에 그대로 보인다 | 같은 일을 두 번 한다. 접는 작업을 미루면 `apps/` 가 계속 비어 있다 |
| **ㄴ 처음부터 Helm 공통 차트 + values** | 레포 구조가 전제하는 끝 모양이다(2.4). 환경 차이(로컬 50 GB → 5 GB)를 values 로 가른다 | 처음 돌려 보기까지가 멀다. 템플릿이 틀렸을 때 원인이 한 겹 숨는다 |
| **ㄷ Kustomize base + overlay** | 환경 차이를 패치로 가르고 템플릿 문법이 없다 | 레포가 Helm 을 적어 뒀고 Argo CD 설정도 Helm 전제다. 둘을 섞으면 주인이 둘이 된다 |

고려 : ㄱ 과 ㄴ 은 배타가 아니다. "생 YAML 로 한 번 관통시키고, 같은 PR 안에서 차트로 접는다" 가 가능하다. 그때는 **관통 로그를 근거로 남기는 것**이 값이다.

### 5.3 로컬에서 이미지 먹이기

| 갈래 | 장점 | 단점 |
|---|---|---|
| **ㄱ 로컬 태그 + `imagePullPolicy: Never`** | 레지스트리가 필요 없다. 지금 있는 `monimo/collector:dev` 를 그대로 쓴다 | EKS values 와 한 줄이 달라진다. 이미지가 없으면 원인이 `ErrImagePull` 이 아니라 `ErrImageNeverPull` 로 나와 헷갈린다. kind 를 고르면 `kind load` 가 더 붙는다 |
| **ㄴ 로컬 레지스트리(`localhost:5000`)를 띄운다** | EKS 와 흐름이 같다(올리고 당긴다). 태그 규칙을 그대로 시험한다 | 컨테이너 하나가 늘고 `insecure-registry` 설정이 붙는다 |
| **ㄷ 바로 ECR 을 쓴다** | 흐름이 EKS 와 완전히 같다 | AWS 계정이 아직 없다(`AGENTS.md` §6). 10/17 준비물에 걸려 있어 **로컬 구간을 막는다** |

### 5.4 신호를 흘리는 쪽 (관통 확인)

2.5 의 표가 그대로 선택지다. 섞을 수도 있다 : `telemetrygen` 으로 경로를 먼저 뚫고, 쇼핑몰은 10/23~24 「팀 API 연동분 차트」 구간에서 올린다.

### 5.5 순서 장치를 로컬에서 어떻게 지키나

ADR `#66` ① 이 "손으로 시작" 으로 정했으니 **자동 장치는 안 만든다.** 다만 손으로 할 때도 모양은 둘로 갈린다

| 갈래 | 장점 | 단점 |
|---|---|---|
| **ㄱ `kubectl apply` 를 순서대로 치는 절차를 README 에 적는다** | 장치가 0 이다. ADR `#66` 과 정확히 같다 | 사람이 빠뜨릴 수 있다. 빠뜨림이 두 번 생기면 ADR `#66` 되돌림 ② |
| **ㄴ 묶어 주는 쉘 스크립트 하나(`scripts/up-local.sh`)** | 한 줄로 끝나고 `kubectl wait --for=condition=complete job/...` 로 성공을 실제로 기다린다 | "손으로" 와 "장치" 사이다. 배포 도구 훅으로 옮길 때 버린다 |

고려 : compose 쪽 선례가 있다. backend 는 `check-dev-infra.sh` · `check-pipeline.sh` 처럼 **쉘 스크립트로 확인**하는 길을 이미 쓰고 있다.

### 5.6 저장소 셋을 우리 YAML 로 쓰나 공개 차트를 쓰나

`plan.md` 가 「1단계 안에서 정할 것」으로 남긴 것이다.

| 갈래 | 장점 | 단점 |
|---|---|---|
| **ㄱ 우리가 생 YAML 로 쓴다** (공식 이미지 StatefulSet) | ADR `#62` F 「공식 이미지 StatefulSet」 그대로다. compose 에 이미 있는 설정(Kafka KRaft 한 대 · ClickHouse 설정 · PG 계정)을 옮겨 쓰면 된다. 5.2 의 kustomize 와 도구가 하나다 | 운영 기능(백업 · 여러 대 · 업그레이드 절차)이 없다. 1b 는 한 대씩이라 당장은 필요 없다 |
| **ㄴ 공개 차트** (Kafka · ClickHouse · PG 각각) | 옵션이 많고 여러 대로 늘리기 쉽다 | Bitnami 는 2025-08 무료 이미지 업데이트를 끊었다(ADR `#62` F 기각 사유). 남는 차트는 저마다 이미지 · 값 이름이 달라 셋을 다 읽어야 한다. kustomize 에 Helm 이 섞인다 |
| **ㄷ 오퍼레이터** (Strimzi · Altinity · CloudNativePG) | 운영 기능이 가장 많다 | 1b 에 과하다. 오퍼레이터 자체가 파드를 먹는다 |

---

## 6. 고르기 (사람 차례)

<!-- 승조가 고른다. 5.1 ~ 5.5 -->

- **5.4 : ③ `telemetrygen` Job** (2026-10-17, 승조 : 「5.4는 telemetrygen으로 정하자」)
  - 근거 : compose 의 `scripts/check-pipeline.sh` 가 이미 `telemetrygen`(`v0.161.0`)으로 신호를 넣고 ClickHouse 에서 센다. 쿠버네티스에서도 같은 시험을 옮기는 것이라 비교가 된다
  - 모양 : 쏘기는 Job 하나, 세기는 ClickHouse 파드에 `SELECT count()`. 둘을 쿠버네티스용 점검 스크립트 하나로 묶는다
  - 알고 쓰는 것 : `telemetrygen` 서비스 이름은 등록돼 있지 않아 `agents` 에는 안 들어간다(backend `#66`). 점검은 spans · metrics · logs 줄 수로 본다
  - 쇼핑몰을 올리는 것(①)은 이 이슈 밖으로 미룬다
- **5.5 : ㄴ 셸 스크립트 하나** (2026-10-17, 승조 : 「kubectl 명령어를 readme로(이건 나중에 너무 귀찮을 거 같아서 pass) · 하나의 쉘 스크립트로 (이걸로)」)
  - 묶음 셋을 `kubectl apply -k` 로 차례로 넣고, 사이에 `kubectl wait` 로 Ready · Job 성공을 기다린다. 제한 시간을 넘기면 그 자리에서 멈춘다
  - ADR `#66` ① 「손으로 시작」과 어긋나지 않는다 : 사람이 치는 한 줄을 묶었을 뿐 클러스터 안 장치가 아니다. 배포 도구(ArgoCD)가 서면 sync wave 로 옮기고 버린다
- **5.6 : ㄱ 우리 YAML** (2026-10-17, 승조 : 「Yaml (이걸로) · 백업, 스케일링등 직접 해야하지만 지금은 한 대씩이라 가장 맞는 선택인듯」)
  - 공개 차트를 안 고른 이유 : kustomize 에 Helm 이 섞여 도구가 둘이 되고, 셋이 저마다 사용법이 다르고, Bitnami 가 무료 이미지 업데이트를 끊었다(ADR `#62` F)
  - 오퍼레이터를 안 고른 이유 : 1b 에 과하다

---

## 7. 2차 정리

### 고른 것 한 장

| 무엇 | 고른 것 | 언제 · 누가 |
|---|---|---|
| 5.1 로컬 클러스터 | Docker Desktop | `plan.md` 2026-10-16 |
| 5.2 매니페스트 모양 | 생 YAML + kustomize overlay (`base` · `overlays/local` · `overlays/eks`) | `plan.md` 2026-10-16 |
| 5.3 로컬 이미지 | 로컬 빌드 태그 + `imagePullPolicy: IfNotPresent` (명시) | `plan.md` 2026-10-16 · 2026-10-17 실측 |
| 5.4 관통 확인 | `telemetrygen` Job + ClickHouse 줄 수 세기 | 승조 2026-10-17 |
| 5.5 순서 장치 | 셸 스크립트 하나 (`apply -k` 셋 + `kubectl wait`) | 승조 2026-10-17 |
| 5.6 저장소 셋 | 우리 YAML (공식 이미지 StatefulSet + Headless Service + PVC) | 승조 2026-10-17 |

### 넣는 순서 (스크립트가 하는 일)

```
0. 네임스페이스            apply → (기다릴 것 없음)
1. 저장소 셋               apply → wait : 파드 셋 Ready
2. 준비 Job 넷             apply → wait : Job 넷 complete
3. 수집기 · 적재 처리기     apply → wait : 파드 둘 Ready
4. 관통 확인               telemetrygen Job → ClickHouse spans · metrics · logs 줄 수가 늘었는가
```

### 구현 전에 짚을 것 둘 (compose 를 다시 읽다 찾았다, 아직 안 정함)

- **마이그레이션 SQL 을 어디서 가져오나**
  - compose 는 `postgres-migrate` · `clickhouse-migrate` 둘 다 backend 레포의 `./db/postgres` · `./db/clickhouse` 를 **볼륨으로 걸어** 읽는다
  - 쿠버네티스 파드는 backend 레포 폴더를 그대로 걸 수 없다. 그렇다고 이 레포에 SQL 을 복사하면 「스키마 파일은 1a 동안 여기 두지 않는다」(`AGENTS.md` §2)를 깬다
  - 후보 : ① 마이그레이션 이미지에 SQL 을 구워 넣는다(backend 쪽 Dockerfile 손질, EKS 에서도 그대로 쓴다) ② 로컬만 `hostPath` 로 backend 폴더를 건다(로컬 전용 길이 생긴다)
- **인증서 Job(`otlp-certs`)의 결과를 어디에 두나**
  - compose 는 내 컴퓨터 `./certs/` 에 쓰고 수집기가 그 폴더를 읽는다. 파드 안에 쓰면 Job 이 끝나는 순간 사라진다
  - 수집기 TLS 기본값이 꺼짐(`none`)이라 로컬 관통에는 인증서가 필요 없다. 운영은 금고 + External Secrets 로 정해져 있다(ADR `#66` ③)
  - 후보 : ① 로컬에서는 이 Job 을 빼고 「Job 셋」으로 간다(완료 조건 「Job 넷」을 고친다) ② Job 이 결과를 Secret 으로 만든다(Job 에 Secret 쓰기 권한이 붙는다)

---

## 8. 구현 프롬프트

<!-- 승조 차례. AI 가 쓰면 그 사실을 표시한다 -->

> **AI 가 쓴 초안이다** : 2026-10-17 Claude 가 승조의 정리본(2~5절을 읽고 승조가 직접 쓴 메모)을 바탕으로 승조 말투로 썼고, 승조가 확인했다(「어어 8절에 넣어줘」). 정리본의 `Always` 줄 「우리 이미지(ECR)는 에러」는 틀린 데가 있어 빼고 넣었다 : 로컬에서 에러가 나는 것은 Docker Hub 를 가리키는 `monimo/*:dev` 이고, ECR 은 EKS 에서만 쓴다

````
#14 로컬 쿠버네티스에 수집 경로 올리는 거 구현해줘
research.md 6절 7절에 정한 거 기준으로 하면 되고 정리하면 이런 느낌이야

순서
compose 는 depends_on 이 알아서 순서대로 올려 주는데
K8s 는 컨트롤러들이 동시에 움직여서 순서 안 정하면 문제 생기니까
묶음으로 나눠서 apply 하고 사이에 kubectl wait 로 먼저 넣은 게 준비될 때까지 (파드 Ready, Job 성공) 기다렸다가 다음 거 넣는 방식으로 해줘
apply 는 안 기다리고 바로 끝나니까 wait 꼭 넣고 제한 시간 넘으면 거기서 멈추게

0 네임스페이스 (apm data shop)
1 저장소 셋 (kafka clickhouse postgres) → Ready 까지 wait
2 준비 Job 넷 (kafka-init postgres-migrate clickhouse-migrate otlp-certs) → 성공까지 wait
3 수집기 적재 처리기 → Ready 까지 wait
4 telemetrygen 으로 신호 쏘고 ClickHouse spans metrics logs 줄 수 늘었는지 확인

이걸 셸 스크립트 하나로 묶어줘 (README 에 명령어만 적는 건 귀찮을 거 같아서 pass)
스크립트 모양은 backend check-dev-infra.sh check-pipeline.sh 처럼 ok fail 찍는 거 따라가면 될 거 같아

저장소
상태 가져야 하니까 StatefulSet + Headless Service + PVC 로
공개 차트나 오퍼레이터 말고 우리가 생 YAML 로 직접 쓰는 걸로 (지금 한 대씩이라 이게 맞는 듯)
이미지는 공식 이미지 그대로 compose 에 있는 버전 맞춰서
설정값도 compose 에 있는 거 옮겨 오면 됨
로컬은 hostpath 라 볼륨 크기는 overlays/local 에서 작게 덮어써줘
hostpath 가 50GB 를 진짜 잡는지 회수 정책이 뭔지는 PVC 하나로 확인해서 research.md 9절에 적어줘

앱
상태 필요 없으니까 Deployment + Service
관리 포트는 업무 포트 + 10000 이고 readiness 는 /readyz 로

이미지
로컬은 docker 에 있는 monimo/collector:dev monimo/ingester:dev 그대로 쓰고
imagePullPolicy 는 IfNotPresent 로 명시해서 적어줘 (안 적으면 latest 로 바뀔 때 조용히 깨지니까)
같은 태그로 다시 빌드하면 파드 안 바뀌는 거 알고 있어서 rollout restart 두 줄 README 에 적어줘

방식
생 YAML + kustomize 로
base 에 공통 두고 overlays/local overlays/eks 가 다른 것만 덮어쓰는 식
Helm 은 지금 안 씀 (다섯 번 복사하는 게 귀찮아지면 그때 바꿀 거)
폴더 하나 = 배포 단위 하나 규칙은 지켜줘
overlays/eks 는 이미지 줄 자리만 잡아 두고 내용은 비워 둬도 됨

검증
telemetrygen Job 으로 (compose check-pipeline.sh 도 이거 쓰니까 같은 버전 v0.161.0 으로)
파이프라인 뚫렸는지만 보면 됨
telemetrygen 은 등록 안 된 서비스라 agents 에는 안 들어가는 거 알고 있어서 agents 는 안 봐도 됨
쇼핑몰은 이번엔 안 올림

먼저 정해야 하는 거 둘
이건 바로 짜지 말고 선택지랑 트레이드오프 먼저 보여줘
- 마이그레이션 SQL 을 어디서 가져올지 (backend db/ 를 볼륨으로 못 거니까 이미지에 굽기 vs 로컬만 hostPath)
- otlp-certs 결과를 어디 둘지 (로컬은 Job 빼고 셋으로 vs Job 이 Secret 만들기)

하면 안 되는 거
- 비밀값 레포에 올리지 말기 (레포 퍼블릭임)
- 스키마 파일 이 레포에 복사하지 말기
- ArgoCD 는 이번 범위 아님

끝났다는 거
- Job 다 성공 종료
- 수집기 적재 처리기 파드 Ready 에 /readyz 200
- telemetrygen 신호가 ClickHouse 까지 도착
- README 로컬 실행 절 채우기
- AGENTS.md §1 표를 Helm 말고 base overlays 모양으로 고치기, §5 §6 갱신
- plan.md 4단계 이슈 칸 「별 이슈」 → #17
- research.md 9절에 실제로 돌린 로그랑 막힌 거 적기

코드 짜기 전에 바탕화면에 가이드 md 먼저 만들어서 보여주고 내가 보고 나서 진행해줘
````

---

## 9. 프롬프트를 가지고 실제 구현

<!-- 구현 뒤에 쓴다 -->
