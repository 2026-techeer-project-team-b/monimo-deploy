# 리서치 : 1b EKS 배포 기반 결정

- 날짜 2026-10-12 / 관련 이슈 `#9`
- 쓴 도구 : 웹 리서치 서브에이전트 1개(서울 단가 · 도구 근거), backend ADR `#19` `#44` `#49` · Q6, 이 레포 AGENTS.md
- 이 이슈는 결정만 한다. Terraform · 차트 코드는 다음 이슈

> **읽는 순서가 곧 쓰는 순서다.** 1 → 2 → 3(승조 질문) → 4 → 5(선택지) → 6 → 7 → 8(승조 결정).
> 이번에는 대화에서 3 · 5 를 먼저 했고(승조가 A ~ I 를 골랐다), 여기에 근거와 함께 옮겼다. 8 은 AI 가 승조의 선택을 문장으로 옮긴 초안을 승조가 확정한 것이다.

---

## 1. 이번 작업은 무엇을 하는 일인가

- **지금 무엇이 없나** : 1b 는 EKS 위에 Helm · Argo CD 로 올린다(ADR `#19` 보정2, `#44` Terraform). `monimo-deploy` 는 폴더 7개가 전부 비어 있다
- **그래서 무엇을 정하나** : Terraform · 차트를 쓰기 전에 모양을 정하는 9가지. A 리전 · B 노드 크기와 구매 방식 · C 켜 두는 시간 · D 네트워크(밖으로 나가는 길) · E 인그레스(밖에서 들어오는 문) · F Kafka · ClickHouse 띄우는 법 · G 비밀값 경로 · H 이미지 태그 반영 · I 노드 늘리고 줄이기
- **제약** : 예산 월 $150 ~ 300(ADR `#44`, 2026-09-20 확정). Kafka · ClickHouse 단일, Strimzi 금지(`#19`). AWS 자원은 Terraform 한 벌(`#44`). `image.tag` 는 CI 봇이 갱신(이 레포 AGENTS §2)

| | |
|---|---|
| 건드리는 것 | 이 폴더 문서, backend ADR, 이 레포 AGENTS §5 · §6 |
| 건드리지 않는 것 | Terraform · 차트 · 클러스터 (다음 이슈) |

**조사 들어가기 전에 내가 알던 것 (세 줄)** :

- 
- 
- 

## 2. 작업하기 전에 알아야 하는 것

### 2.1 돈이 나가는 곳 (서울 단가)

| 무엇 | 단가 | 출처 · 확신도 |
|---|---|---|
| EKS 컨트롤 플레인 | $0.10/h (월 $73). **노드가 0대여도 나간다** | AWS Price List 2026-09-28 · 높음 |
| EC2 t3.medium · t3.large | $0.052/h · $0.104/h | AWS 가격 JSON 2026-10-09 · 높음 |
| EC2 t3.xlarge · t4g.nano | $0.208/h · $0.0052/h | 제3자(DoiT) · 중간 |
| Spot t3.large | $0.0104 ~ 0.0349/h, 중단 빈도 <5% | 제3자(DoiT) · 중간 |
| Spot t3.xlarge · m6i.large | 중단 빈도 5 ~ 10% · **>20%** | 제3자 · 중간 |
| NLB | $0.0225/h + $0.006/NLCU-h. **정지 기능이 없다** | AWS Price List 2026-09-11 · 높음 |
| 퍼블릭 IPv4 | $0.005/h 하나당 (EC2 · NLB · NAT · EIP 전부) | AWS Price List 2026-09-17 · 높음 |
| NAT 게이트웨이 | $0.059/h + $0.059/GB | 2023 블로그 · 낮음 |
| EBS gp3 | $0.0912/GB-월 | 제3자 · 중간 |
| RDS PostgreSQL db.t4g.micro 단일 AZ | 약 $0.0247/h (월 $18) | 제3자 2026-09-28 · 중간 |
| Secrets Manager | $0.40/비밀-월 + API 1만 회당 $0.05 | AWS · 높음 |
| ECR | $0.10/GB-월, 같은 리전 pull 무료 | AWS · 높음 |

### 2.2 온디맨드와 Spot (가격 말고)

- Spot 은 AWS 가 그 자원이 필요해지면 **2분 예고 뒤 노드를 회수**한다. 그 타입에 남는 자원이 없으면 **아예 안 뜰 수도** 있다(그래서 타입을 2 ~ 3개 섞어 지정)
- 관리형 노드 그룹은 Spot 을 지원하고, 회수 신호가 오면 미리 새 노드를 띄우는 용량 재조정이 켜진다. AWS 문서가 **StatefulSet · DB 는 온디맨드에 두라**고 권한다
- 그래서 나눈다 : 데이터(Kafka · ClickHouse)는 온디맨드, 다시 뜨면 그만인 앱(backend · 쇼핑몰 · 화면)은 Spot

### 2.3 노드를 끄면 데이터는? (켜 두는 시간)

| 데이터 | 있는 곳 | 노드를 0대로 내리면 |
|---|---|---|
| Kafka · ClickHouse | EBS 디스크(PVC) | 남는다. 같은 AZ 노드가 다시 뜨면 다시 붙는다 |
| PostgreSQL | RDS | 남는다. RDS 는 최대 7일 정지, 7일 뒤 자동 기동. 정지 중에도 스토리지 · 백업 · IPv4 는 과금 |
| 이미지 | ECR | 남는다 |
| 파드 메모리 · 임시 폴더 | 노드 | 사라진다(원래 잃어도 되는 것) |

지킬 것 셋 : ① StorageClass `reclaimPolicy: Retain` (기본은 Delete) ② `volumeBindingMode: WaitForFirstConsumer` + **데이터 노드 그룹을 한 AZ 에 고정**. EBS 는 만들어진 AZ 에서만 붙고, 그 AZ 에 노드가 없으면 파드가 `volume node affinity conflict` 로 멈춘다 ③ 끄는 것은 노드 그룹 `desiredSize=0` 이지 `terraform destroy` 가 아니다.

켜고 끄는 법 : 노드 그룹 `minSize` · `desiredSize` 는 0 까지 된다(`maxSize` 는 최소 1). EKS 는 ASG 값이 바뀌면 노드 그룹을 맞춰 주므로 **ASG 예약 작업(cron, 시간대 지정, 최대 2분 지연)** 으로 켜고 끈다. Terraform 으로 같이 만든다.

### 2.4 NAT 인스턴스 (fck-nat)

- NAT 게이트웨이 대신 작은 EC2 를 NAT 로 쓰는 오픈소스 AMI. t4g.nano 로 순간 최대 5Gbps
- Terraform 모듈 `RaJiska/terraform-aws-fck-nat` (Terraform ~>1.9, AWS provider >=6.0, 기본 타입 t4g.micro). HA 모드는 ASG + 옮겨 붙는 ENI 로 인스턴스가 죽으면 새로 띄운다. 문서 스스로 "완전히 면역은 아니다" 라고 쓴다
- 월 약 $7.5 (인스턴스 + IPv4) 대 NAT 게이트웨이 약 $43 + 데이터 처리비

### 2.5 Kafka · ClickHouse 이미지

- Bitnami 는 2025-08-28 부터 버전 태그 이미지를 `bitnamilegacy` 로 옮기고 **업데이트를 멈췄다.** 전체 카탈로그는 유료(BSI). 차트 기본값이 아직 옛 이미지를 가리켜 그대로 쓰면 안 된다
- 공식 이미지 `apache/kafka`(KRaft 기본, `KAFKA_*` env) · `clickhouse/clickhouse-server`(`/var/lib/clickhouse`, nofile 262144) 로 StatefulSet 을 직접 만든다. 로컬 compose 설정을 거의 그대로 옮길 수 있다

### 2.6 인그레스 : Traefik + NLB 로 HTTP 와 gRPC 를 한 문에

- 수집기는 gRPC(OTLP 4317), 화면 · API 는 HTTP. Traefik 은 백엔드로 `scheme: h2c` 를 주면 gRPC 를 그대로 넘긴다
- NLB 는 L4(연결 단위 분산). TLS 를 Traefik 에서 끝내면 한 입구가 ALPN 으로 HTTP 와 gRPC 를 같이 받는다(추정, 첫 기동 때 확인)
- 주의 : NLB TCP 유휴 타임아웃 기본 350초. 오래 열어 두는 gRPC 연결은 keepalive 필요. 인증서는 cert-manager HTTP-01(80 포트 열림 필요)
- NLB 는 끌 수 없다. 스케줄로 끄려면 Service 를 지웠다 다시 만들어야 하고 그때마다 DNS 이름이 바뀐다 → **24시간 유지**

### 2.7 비밀값 : External Secrets Operator

- Secrets Manager 값을 k8s Secret 으로 자동 동기화. 인증은 IRSA 또는 EKS Pod Identity(컨트롤러 자격증명만 씀)
- 경로 접두사를 쓰면 한 번에 여러 값을 가져와 API 호출이 준다. 비밀 5개면 월 약 $2

### 2.8 이미지 태그 : CI 가 deploy 레포에 커밋

- Argo CD 본체는 "git 에 적힌 상태를 클러스터에 맞추는 일" 만 한다. 새 이미지가 나왔는지는 모른다. 그래서 새 태그를 git 에 넣는 누군가가 따로 필요하다
- CI 는 GitHub OIDC 로 AWS 에 로그인(`configure-aws-credentials`, `id-token: write`, `role-to-assume`)해 ECR 에 푸시하고, **GitHub App 토큰**(`create-github-app-token`, 1시간 만료 · 레포 지정)으로 deploy 레포에 `image.tag` 를 커밋한다. 개인 PAT · deploy key 는 오래 살아 있는 자격증명이라 쓰지 않는다
- 주의 : 2026-07-15 이후 만든 레포는 OIDC `sub` 클레임 형식이 `repo:org@ID/repo@ID:...` 로 바뀌었다. IAM 신뢰 정책을 그 형식으로 써야 한다

### 2.9 자주 헷갈리는 것

| 헷갈리는 것 | 실제 |
|---|---|
| 노드를 끄면 EKS 비용이 0 | 컨트롤 플레인 $73 은 계속 나간다 |
| 노드를 끄면 데이터가 날아간다 | EBS · RDS 에 있어서 남는다. `Retain` · 단일 AZ · destroy 금지만 지키면 |
| Argo CD 를 쓰면 Image Updater 가 필수 | 아니다. 태그를 git 에 넣는 방법이 둘이고 CI 커밋도 표준이다 |
| NLB 도 같이 끄면 된다 | 정지 기능이 없고, 다시 만들면 주소가 바뀐다 |
| Bitnami 차트를 그대로 쓰면 빠르다 | 2025-08 이후 무료 이미지 업데이트가 끊겼다 |
| Spot 은 그냥 싼 온디맨드 | 2분 예고 회수 · 못 받을 수 있음. 데이터는 올리지 않는다 |

## 3. 1차 질문 (사람 차례)

대화에서 승조가 물은 것 (2026-10-12) :

- **Q. 온디맨드와 Spot 은 가격 말고 무엇이 다른가** → 2.2. 회수 · 못 받음 · 파드 이동. 데이터는 온디맨드, 앱은 Spot
- **Q. 특정 시간에만 서버를 켜면 데이터가 전부 날아가는 것 아닌가** → 2.3. 노드만 내리고 데이터는 EBS · RDS 에 남는다
- **Q. K8s + Argo CD 면 Image Updater 를 써야 하는 것 아닌가** → 2.8. 필수가 아니고, ADR 에 적힌 CI 커밋이 도구가 하나 적고 PR 과 기록이 이어진다
- **Q. 로컬에서 k8s · Argo CD 를 먼저 확인할 수 있지 않나** → 된다(Helm · Argo · 관통 · 인그레스 · 스키마 Job · 디스크 보존). AWS 쪽(VPC · NAT · IAM · EBS AZ · Spot · NLB · ECR OIDC)은 EKS 에서만 확인된다. 로컬은 Docker Desktop k8s, 전부 띄움, 측정 때 다른 프로젝트 컨테이너를 내리고 Docker 메모리 22 ~ 24GB 로 증설. 시점은 미정(별도 이슈)

## 4. 1차 정리

- 데이터는 노드 밖(EBS · RDS)에 있으므로 노드는 켜고 끄는 대상이다. 끌 수 없는 고정비는 EKS $73 · NLB 약 $28 · NAT 인스턴스 약 $7.5 · 디스크다
- 상태 있는 것(Kafka · ClickHouse)만 온디맨드 · 한 AZ, 나머지는 Spot
- 문은 Traefik + NLB 하나로 HTTP 와 gRPC 를 같이 받는다
- 공식 이미지로 StatefulSet 을 직접 만든다(Bitnami 이미지 업데이트 중단)
- 비밀은 Secrets Manager → ESO, 태그는 CI → GitHub App 토큰 → deploy 레포 커밋

## 5. 선택지와 설명

| | 정할 것 | 선택지 | 고른 것 (승조) | 버린 것과 이유 |
|---|---|---|---|---|
| A | 리전 | 서울 / 미국 동부 | **서울** | 미국 동부 : 10 ~ 20% 싸지만 화면 · API 왕복 150ms+ |
| B | 노드 | 온디맨드만 / Spot 만 / 섞기 | **데이터 온디맨드 t3.large 1대(한 AZ) + 앱 Spot t3.large 2대** (Spot 타입은 2 ~ 3개 섞어 지정) | 온디맨드만 : 앱까지 비쌈. Spot 만 : Kafka · ClickHouse 가 같이 회수되면 멈춤. m6i.large Spot 은 중단 >20% 라 제외 |
| C | 켜 두는 시간 | 24시간 / 밤에만 끔 / 정해진 시간에만 켬 | **정해진 시간에만 켬** (노드 그룹 ASG 예약 작업). NLB · NAT 인스턴스 · EKS 는 24시간 | 24시간 : 노드 비용 그대로. 수동 : 깜빡하면 새거나 필요할 때 꺼져 있음 |
| D | 밖으로 나가는 길 | NAT 게이트웨이 / 공개 서브넷 / NAT 인스턴스 | **NAT 인스턴스 (fck-nat, t4g.nano)** | NAT 게이트웨이 : 월 약 $43 + 데이터비. 공개 서브넷 : 노드가 인터넷에 직접 노출 |
| E | 들어오는 문 | ALB / Traefik + NLB / Gateway API | **Traefik + NLB** | ALB : 월 $20+ 에 gRPC 설정 추가, AWS 에 묶임. Gateway API : 자료 적음 |
| F | Kafka · ClickHouse | 직접 StatefulSet + EBS / 커뮤니티 차트 / 관리형 | **공식 이미지로 직접 StatefulSet + EBS (Retain · 한 AZ)** | Bitnami : 무료 이미지 업데이트 중단. MSK 등 : 월 $100+ |
| G | 비밀값 | ESO / CSI 드라이버 / Terraform 이 Secret 생성 | **External Secrets Operator** | CSI : 파일 마운트라 env 로 쓰려면 한 단계 더. Terraform : state 에 평문 |
| H | 이미지 태그 | CI 가 deploy 레포 커밋 / Argo CD Image Updater | **CI 커밋 (GitHub App 토큰)** | Image Updater : 도구 하나 더, write-back 켜야 기록 남음, 성숙도 낮음, ADR 과 다름 |
| I | 노드 늘리고 줄이기 | 관리형 노드 그룹 고정 / Karpenter | **관리형 노드 그룹 + 고정 대수** | Karpenter : 학습 · Terraform 복잡. 서비스 개수가 정해져 있어 1b 엔 과함 |

PostgreSQL 은 `#44` 가 이미 RDS 로 정했다 : db.t4g.micro 단일 AZ, 노드와 같은 시간에만 켠다.

### 5.1 월 비용 (730시간 기준, 켜는 시간 = 평일 약 220시간 가정)

| 항목 | 계산 | $ |
|---|---|---|
| EKS 컨트롤 플레인 (24시간) | 0.10 × 730 | 73.00 |
| 데이터 노드 t3.large 온디맨드 (220h) | 0.104 × 220 | 22.88 |
| 앱 노드 Spot t3.large × 2 (220h, 상단가) | 0.0349 × 220 × 2 | 15.36 |
| NAT 인스턴스 t4g.nano + IPv4 (24시간) | (0.0052 + 0.005) × 730 | 7.45 |
| NLB + 1 NLCU + IPv4 2개 (24시간) | (0.0225 + 0.006 + 0.005 × 2) × 730 | 28.11 |
| EBS gp3 100GB | 0.0912 × 100 | 9.12 |
| RDS t4g.micro (220h) + 20GB | 0.0247 × 220 + 20 × 약 0.131 | 약 8.0 |
| Secrets Manager 5개 | 5 × 0.40 | 2.00 |
| ECR 10GB | 10 × 0.10 | 1.00 |
| **합계** | | **약 $167** |

- 데이터 노드를 24시간 켜 두면 **약 $220**, Spot 을 못 받아 앱도 온디맨드면 여기에 약 $30
- 빠진 것 : 노드 루트 디스크, 인터넷 전송료, CloudWatch, 부가세
- 예산 $150 ~ 300 안이다. 가장 큰 몫은 끌 수 없는 EKS $73 과 NLB $28

## 6. 2차 질문 (사람 차례)

## 7. 2차 정리

- 고른 것 : 5 절 표 굵은 글씨. 결정을 가르는 기준은 예산 안인가, 데이터를 잃지 않는가, 도구 수가 적은가, ADR 과 맞는가
- 켜는 시간 : 발표(10/31) 전까지는 거의 상시로 켜 두고, 정해진 시간 스케줄은 발표 뒤부터 적용한다
- 일정 (2026-10-12 승조 확정, 10/31 발표 · 데모 촬영 2일)

```
~10/17    백엔드 수집 마무리 + #9 확정 + AWS 계정 · 도메인 · GitHub App 준비 (팀원 : API 연동)
10/18~21  로컬 k8s(Docker Desktop) 수집 쪽 : 쇼핑몰 → 수집기 → Kafka → 적재 → CH
10/20~23  Terraform 작성, 22~23 첫 apply (VPC · NAT 인스턴스 · EKS 만, 확인 뒤 노드 0대)
10/23~24  팀 API 연동분 차트 추가 + 로컬 전체 관통 (= 데모 비상 대책)
10/25~27  CI → ECR, External Secrets, EKS 에 Argo CD, values 교체, 관통
10/28     안정화 · 버퍼
10/29~30  데모 촬영 (EKS, 안 되면 로컬 k8s)
10/31     발표
```

- 압축 일정이라 ADR `#44` 되돌림("Terraform 초기 세팅이 첫 주를 넘기면 eksctl")을 **이틀**로 당긴다

### 여기서 나온 면접 질문

1. EKS 비용을 어떻게 예산 안에 넣었나. 끌 수 있는 것과 없는 것은
2. Spot 을 어디에 쓰고 어디에 안 썼나. 이유는
3. 노드를 매일 껐다 켜는데 Kafka · ClickHouse 데이터는 어떻게 지키나
4. NAT 게이트웨이를 안 쓴 이유와 대가
5. 한 입구로 HTTP 와 gRPC 를 어떻게 같이 받나
6. Argo CD 를 쓰면서 이미지 태그는 누가 바꾸나

## 8. 구현 프롬프트 (사람 차례)

> 승조가 대화에서 고른 것(A ~ I)을 AI 가 문장으로 옮긴 초안을 승조가 "어 이거 마무리하자" 로 확정했다. 켜는 시간 줄은 AI 가 제안한 "발표 전 상시, 발표 후 스케줄" 을 승조가 같이 받아들였다. 같은 원문이 [`prompts.md`](prompts.md) 에 있다.

```
리전은 서울로 가자

노드는 데이터랑 앱을 나누자 Kafka랑 ClickHouse는 온디맨드 t3.large 1대를 한 AZ에 고정하고 앱은 Spot t3.large 2대로 (Spot 타입은 2~3개 섞어서 지정)
Spot은 2분 예고로 회수되니까 데이터는 올리지 않는다

서버는 정해진 시간에만 켜자 노드 그룹을 ASG 예약 작업으로 켜고 끄고 RDS도 같은 시간에 맞춘다
발표(10/31) 전까지는 거의 상시로 켜 두고 스케줄은 발표 뒤부터 적용한다
노드만 내리는 거라 데이터는 EBS랑 RDS에 남는다 대신 StorageClass는 Retain, 데이터 노드는 한 AZ, terraform destroy는 쓰지 않는다
EKS 컨트롤 플레인, NLB, NAT 인스턴스는 24시간 켜 둔다 (NLB는 끌 수 없고 다시 만들면 주소가 바뀐다)

NAT 게이트웨이는 비싸니까 NAT 인스턴스(fck-nat, t4g.nano)로 가자

인그레스는 Traefik + NLB로 HTTP랑 수집기 gRPC를 한 문으로 받자 인증서는 cert-manager

Kafka랑 ClickHouse는 공식 이미지로 StatefulSet을 직접 만들고 EBS에 둔다 Bitnami는 무료 이미지 업데이트가 끊겨서 패스

비밀값은 Secrets Manager에 두고 External Secrets Operator로 넣자

이미지 태그는 CI가 ECR에 푸시하고 GitHub App 토큰으로 deploy 레포에 image.tag를 커밋하자 Image Updater는 도구가 하나 늘고 ADR이랑 달라서 패스

노드 그룹은 관리형 + 고정 대수로 가자 Karpenter는 나중에

예상 비용은 월 약 167달러 (데이터 노드를 24시간 켜면 약 220달러)
```
