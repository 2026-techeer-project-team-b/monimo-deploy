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

로컬에서 바뀌는 것은 **볼륨 종류 하나**다. EBS 가 없으니 기본 `storageClass`(Docker Desktop 은 `hostpath`)를 쓴다. 50 GB 를 그대로 요구하면 내 디스크에서 그만큼 잡으므로 로컬 values 에서 줄일 자리가 필요하다.

### 2.3 로컬에서 이미지를 어떻게 먹이나가 EKS 와 가장 다른 점이다

EKS 는 CI 가 ECR 에 올리고 봇이 `image.tag` 를 이 레포에 커밋한다(ADR `#62`). 로컬에는 ECR 도 CI 도 없다.

- 지금 로컬에 있는 것 : `monimo/collector:dev` · `monimo/ingester:dev`(backend `#170` Dockerfile 하나 · 멀티스테이지 · `target`)
- 지금 도커 상태 : Docker Desktop `29.2.1`, 이미지 저장소가 **containerd**(`io.containerd.snapshotter.v1`)
- Docker Desktop 쿠버네티스는 같은 containerd 를 쓰므로 **로컬에서 만든 태그를 레지스트리 없이 쓸 수 있을 것**이다. 다만 `imagePullPolicy` 를 `Never` 나 `IfNotPresent` 로 두지 않으면 쿠버네티스가 Docker Hub 에서 `monimo/collector` 를 당기려 하고 **없는 이미지라 `ErrImagePull` 로 멈춘다**
- **확인 안 됨** : 클러스터가 아직 꺼져 있어 실제로 되는지는 못 봤다. 5.3 의 선택지가 여기서 나온다

### 2.4 레포 구조가 이미 "차트 + values" 를 전제한다

`AGENTS.md` §1 이 `charts/` 를 "공통 차트(서비스용 · 쇼핑몰용)", `apps/` 를 "서비스별 values, **폴더 하나 = 배포 단위 하나**" 로 적어 뒀고, §2 가 "한 폴더에 서비스 두 개의 values 를 섞지 않는다" 를 깨면 안 되는 규칙으로 뒀다.

즉 생 YAML 로 시작하더라도 **끝 모양은 차트 + values** 다. 고를 것은 "지금부터 차트로 쓸지, 생 YAML 로 한 번 돌려 보고 차트로 접을지" 라는 순서뿐이다.

도구 상태 : `kubectl v1.34.1` · `helm v4.2.0` 설치돼 있다. `kind` · `minikube` 는 없다. 컨텍스트 `docker-desktop` 은 있는데 **클러스터가 꺼져 있다**(`127.0.0.1:6443` 연결 거부).

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

---

## 6. 고르기 (사람 차례)

<!-- 승조가 고른다. 5.1 ~ 5.5 -->

---

## 7. 2차 정리

<!-- 6절 뒤에 쓴다 -->

---

## 8. 구현 프롬프트

<!-- 승조 차례. AI 가 쓰면 그 사실을 표시한다 -->

---

## 9. 프롬프트를 가지고 실제 구현

<!-- 구현 뒤에 쓴다 -->
