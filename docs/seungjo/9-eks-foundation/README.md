# `#9` 1b EKS 배포 기반 결정

> **이 작업의 기술 설계 문서 한 장.** 문제 → 선택지 → 결정 → 다음 순서로 읽으면 끝난다.
> 하네스 규칙과 틀은 backend [`docs/seungjo/`](https://github.com/2026-techeer-project-team-b/monimo-backend/blob/HEAD/docs/seungjo/README.md) 가 정본이다.

- 2026-10-12 / 승조(`@SeungJo-02`) / ADR backend `#62` (`#19` · `#44` 구체화) / 이슈 `#9`
- 유저 플로우에서 어디 : 전부. 쇼핑몰 · 수집 · 저장 · 조회 · 알림이 올라갈 자리를 정한다

## 문제

1b 는 EKS 위에 Helm · Argo CD 로 올린다(ADR `#19` 보정2, `#44`). 이 레포 폴더 7개가 비어 있고, Terraform · 차트를 쓰기 전에 모양을 정해야 한다. 예산은 월 $150 ~ 300, 발표는 10/31.

## 선택지와 결정

전체 표 · 근거 · 단가 출처는 [`research.md`](research.md) 2 · 5 절.

| | 정할 것 | 고른 것 | 버린 것과 이유 |
|---|---|---|---|
| A | 리전 | 서울 | 미국 동부 : 싸지만 왕복 150ms+ |
| B | 노드 | 데이터 온디맨드 t3.large 1대(한 AZ) + 앱 Spot t3.large 2대 | Spot 만 : 데이터가 같이 회수됨 · 온디맨드만 : 비쌈 |
| C | 켜는 시간 | 정해진 시간만 (ASG 예약 작업), 발표 전엔 상시 | 24시간 : 노드 비용 그대로 |
| D | 나가는 길 | NAT 인스턴스 fck-nat t4g.nano (월 약 $7.5) | NAT 게이트웨이 : 월 약 $43 + 데이터비 · 공개 서브넷 : 노드 노출 |
| E | 들어오는 문 | Traefik + NLB, cert-manager. **개정(backend `#159` · ADR `#64`) : 수집기 gRPC 통로는 입구에 두지 않는다.** 화면 · API 의 HTTP 만 받는다 | ALB : gRPC 설정 추가 · AWS 에 묶임 |
| F | Kafka · ClickHouse | 공식 이미지 StatefulSet + EBS(Retain) | Bitnami : 2025-08 무료 이미지 업데이트 중단 · 관리형 : 월 $100+ |
| G | 비밀값 | Secrets Manager + External Secrets | CSI : 파일 마운트 · Terraform : state 평문 |
| H | 이미지 태그 | CI 가 GitHub App 토큰으로 deploy 레포 커밋 | Image Updater : 도구 추가 · ADR 과 다름 |
| I | 노드 수 | 관리형 노드 그룹 고정 | Karpenter : 1b 에 과함 |

- **월 비용** : 정해진 시간(평일 약 220시간)만 켜면 약 $167, 데이터 노드 24시간이면 약 $220. 끌 수 없는 고정비는 EKS $73 · NLB 약 $28 · NAT 인스턴스 약 $7.5
- **개정 (2026-10-13, backend `#159` 에이전트 mTLS · ADR `#64`)** : E 에서 "수집기 gRPC(h2c)" 를 뺀다. 쇼핑몰은 클러스터 안에서 서비스 이름으로 수집기에 붙어 입구를 안 지나므로 입구의 인증은 안쪽 공격을 못 막고, 입구에서 TLS 를 끝내면 수집기가 보는 상대 주소가 입구 주소가 되어 backend `#149`(파드 명부 주소)가 깨진다. 그래서 **바깥 에이전트를 받지 않기로** 했고 TLS 는 수집기가 직접 끝낸다(mTLS, 손님 신분증 도장 검사). 입구는 HTTP 만 받아 설정이 가벼워지고 NLB 는 화면 · API 때문에 그대로 필요하다. 바깥 에이전트를 받기로 하면 그때 입구 쪽을 다시 본다(ADR `#64` 되돌림 ①)
- **되돌리는 조건** : Terraform 첫 apply 가 이틀 넘게 막히면 eksctl 로 내린다(`#44` 의 "첫 주" 를 일정 때문에 당김). Spot 을 계속 못 받으면 앱도 온디맨드(+ 약 $30). 데이터 노드 AZ 에 문제가 생기면 그 AZ 로 노드를 다시 띄운다

결정 원문은 [`research.md`](research.md) 8 절과 [`prompts.md`](prompts.md).

## 다음

```
~10/17    백엔드 수집 마무리 + AWS 계정 · 도메인 · GitHub App 준비 (팀원 : API 연동)
10/18~21  로컬 k8s(Docker Desktop) 수집 쪽
10/20~23  Terraform 작성, 22~23 첫 apply (VPC · NAT 인스턴스 · EKS 만)
10/23~24  팀 API 연동분 차트 + 로컬 전체 관통 (= 데모 비상 대책)
10/25~27  CI → ECR, External Secrets, Argo CD on EKS, 관통
10/28     안정화 · 버퍼 / 10/29~30 데모 촬영 / 10/31 발표
```

## 이 이슈에서 배운 것 (세 줄)

- 노드를 꺼도 데이터는 EBS · RDS 에 남는다. 끌 수 없는 고정비(EKS · NLB · NAT)가 예산의 절반이다
- Spot 은 가격이 아니라 "회수된다" 가 본질이라 상태 있는 것에 올리지 않는다
- Argo CD 는 git 을 클러스터에 맞출 뿐이고, 새 태그를 git 에 넣는 일은 따로 정해야 한다
