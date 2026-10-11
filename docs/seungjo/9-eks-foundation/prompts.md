# 2026-10-12 1b EKS 배포 기반 결정

- 관련 이슈 : `#9`
- 쓴 도구 : 웹 리서치 서브에이전트 1개(서울 단가 · fck-nat · 노드 그룹 스케줄 · EBS CSI · Bitnami · Traefik gRPC · ESO · ECR OIDC · 비용 계산), backend ADR `#19` `#44` `#49` · Q6 읽기
- 결과물 : [`research.md`](research.md) · 설계 한 장 [`README.md`](README.md). 코드는 없다

## 프롬프트

시작 (승조, 원문) :

```
일단 MSA 프로젝트이기 때문에 1b(Terraform→EKS→Helm·Argo CD) 로 할 예정이고
```
```
그럼 1번 진행을 하면 될 거 같은데 선택 해야하는 것이 뭐가 있는 지 각각의 선택지에 대한 트레이드오프를 알려줘
```

선택 (승조, 원문 두 번) :

```
A 서울
B 온디맨드랑 SPOT 이 가격 말고 어떤 면에서 차이점이 있어?
C 가능하면 특정 시간에만 서버가 올라갈 수 있도록
D 네트워크 쪽은 NAT네트워크는 돈이 너무많이 들어가서 문제가 좀 될 거 같다...
E 추천방식으로 가자
F 안전한 EBS 방식으로 하자
G External Secrets 방식으로
H Argo CD로
I 관리형 노드 그룹 + 고정 대수 로 하면 될 거 같은데
```
```
D는 NAT로 가자
C를 저렇게 가면 서버가 내려가면 데이터도 전부 날아가는 거 아니야?
B는 데이터는 온디멘드 앱은 SPOT으로 가자
H의 경우는 우리가 K8s + ArgoCD를사용할 예정인데 Argo CD Image Updater 사용해야 하는 거 아닌가?
```
```
D는  NAT 인스턴스, H는 CI가 deploy 레포에 커밋 으로 하자
```

조사 단계 (메인 대화 → 웹 리서치 서브에이전트) : 서울 단가(EKS · EC2 · Spot · EBS · NLB · RDS · NAT · IPv4), fck-nat, 노드 그룹 0대 · 예약 작업 · RDS 7일 규칙, EBS CSI Retain · AZ, Bitnami 2025 정책, Traefik + NLB gRPC, ESO 인증 · 요금, GitHub OIDC · App 토큰, 월 비용 계산. 확신도는 research 2.1 표에 항목별로 적었다.

일정 (승조, 원문) :

```
일단 17일 까지 벡엔드 완성 + 타 팀원들 API 연동
24일까지 추가 API 연동 +  버그 수정 및 로컬 K8s 환경 구성
28일 까지 배포 예정 이렇게 잡았는데 괜찮으려나?
```
```
31일이 발표다 그래서 대모 찍을 2일이 필요할 듯
```

결정 (research 8 절. AI 가 위 선택을 문장으로 옮긴 초안을 승조가 "어 이거 마무리하자" 로 확정) :

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
