# 2026-10-19 로컬 ArgoCD

- 관련 이슈 : `#20`
- 쓴 도구 : ArgoCD `v3.5.5` 공식 문서(`operator-manual/health.md`) 확인, 로컬 클러스터 실측(빈 클러스터부터 두 번), 코드 리뷰 서브에이전트 1개(구현 뒤, 만든 쪽과 다른 자리)
- 결과물 : [`research.md`](research.md) 9절 · 바탕화면 가이드(레포 밖) · `argocd/` · `scripts/{lib,local-prereqs,check-local,up-argocd}.sh` · base 주석

## 프롬프트

구현 프롬프트 : `research.md` 8절 (Claude 가 승조 정리본으로 초안, 승조 확인)

시작 (승조, 원문) :

```
프롬프트를 바탕으로 구현을 진행해줘
```

가이드를 보고 고른 것 (승조, 원문) :

```
추천대로 진행하자 그리고 프롬프트에(8절)기반하여 구현 진행해줘
```

- 「추천」 : 가이드 ① root 만 manual · 자식 automated(prune · selfHeal 끔), ② `telemetrygen` 은 ArgoCD 에 안 넣고 `check-local.sh`

## AI 가 틀렸던 것 · 잡은 방법

| 무엇 | 어떻게 잡았나 |
|---|---|
| 7절 ② 를 「hook 만 든 자식은 Job 이 끝나기 전에 Healthy 로 보일 수 있다」로 적었다. 실제는 Job 이 **아예 안 돌았다** (automated 는 OutOfSync 일 때만 sync 하는데 hook 만 든 자식은 처음부터 Synced) | 패치 없이 먼저 돌린 실측에서 `data` 에 Job 이 하나도 없는 것을 보고 찾았다. Job 셋을 `local-apps` 의 PreSync 로 옮겼다 |
| 8절 프롬프트는 자식까지 전부 manual 이었다 : 그러면 root sync 가 자식마다 멈춰 선다 | 가이드를 쓰며 sync wave 가 자식 Healthy 를 기다리는 방식을 따라가다 찾았다. 승조에게 물어 정했다 |
| StatefulSet 이 diff 없이 계속 OutOfSync | `#14` 매니페스트의 `volumeClaimTemplates` 에 `apiVersion` · `kind` 가 없었다. 클러스터 쪽 값을 직접 보고 찾았다 |
| 실패한 PreSync 를 다시 할 길(`retry`)과 끝나지 않는 Job 의 한도(`activeDeadlineSeconds`)가 없었다 | 리뷰 서브에이전트가 찾았다 (승인 · 중간 1 · 낮음 5). 중간 하나 · 낮음 다섯 다 반영했다 |
