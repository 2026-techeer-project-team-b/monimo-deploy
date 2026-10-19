#!/usr/bin/env bash
# 로컬 쿠버네티스(Docker Desktop)에 ArgoCD 를 띄우고 root Application 을 넣는다 (#20). kubectl 로 묶음을 넣는 up-local.sh 와 다른 길이다
#
#   ./scripts/up-argocd.sh           레포 밖 준비물(local-prereqs.sh) → ArgoCD 설치 → root 넣기 → UI 들어가는 법 출력
#   ./scripts/up-argocd.sh --down    지우기 (argocd · apm · data · shop 네임스페이스, PVC 도 같이 지워진다. CRD 같은 클러스터 단위 자원은 남는다)
#
# 순서는 이 스크립트가 아니라 sync wave 가 지킨다 (argocd/apps/local 의 번호표 0 → 3). 이 스크립트는 root 를 sync 하지 않는다 :
# 로컬은 사람이 root 를 Sync 해서 시작한다 (manual). 끝나면 ./scripts/check-local.sh 로 관통을 본다
set -euo pipefail
. "$(dirname "$0")/lib.sh"

case "${1:-}" in
  ""|--down) ;;
  *) echo "✗ 모르는 인자 $1 (쓸 수 있는 것 : 없음 · --down)"; exit 1 ;;
esac

require_local_context

if [ "${1:-}" = --down ]; then
  [ "$CONTEXT" = docker-desktop ] || fail "--down 은 docker-desktop 에서만 한다 (지금 $CONTEXT)"
  # Application 에 finalizer 가 없어 Application 을 지워도 자원은 남는다 : 네임스페이스째 지운다.
  # ArgoCD 의 클러스터 단위 자원(CRD · ClusterRole …)은 남는다. 다시 올릴 때 server-side apply 로 덮어써서 해가 없다
  k delete ns argocd apm data shop --ignore-not-found
  ok "네임스페이스 넷 지움 (로컬 hostpath 는 회수 정책이 Delete 라 볼륨도 같이 지워진다)"
  exit 0
fi

# ── 1 (이미지 · backend 폴더가 없으면 ArgoCD 를 깔기 전에 멈춘다)
"$ROOT/scripts/local-prereqs.sh"

# ── 2
step "2 ArgoCD 설치 (argocd/install : 공식 install.yaml 고정 버전 + Application 상태 판정)"
k create namespace argocd --dry-run=client -o yaml | k apply -f - > /dev/null
# CRD 가 커서 일반 apply 는 주석 크기 한도에 걸린다 : 공식 문서대로 server-side
k apply -k "$ROOT/argocd/install" --server-side --force-conflicts > /dev/null
for d in $(k -n argocd get deployment -o name); do wait_rollout argocd "$d"; done
wait_rollout argocd statefulset/argocd-application-controller

# ── 3
step "3 root Application"
k apply -f "$ROOT/argocd/root.yaml" > /dev/null
ok "root → argocd/apps/local ($(k -n argocd get application root -o jsonpath='{.spec.source.targetRevision}'))"

cat <<'MSG'

── 다음은 사람이 한다
  UI       kubectl -n argocd port-forward svc/argocd-server 8080:443   →  https://localhost:8080 (인증서 경고는 넘긴다)
  계정     admin / kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
  CLI      argocd login localhost:8080 --username admin --insecure
  시작     UI 에서 root → Sync (또는 argocd app sync root). 자식 셋이 번호 0 → 1 → 3 순서로 서서 스스로 sync 한다
  확인     argocd app list  (root + 자식 셋, 넷 다 Synced · Healthy)  →  ./scripts/check-local.sh
MSG
