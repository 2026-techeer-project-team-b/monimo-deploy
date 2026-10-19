#!/usr/bin/env bash
# 로컬 쿠버네티스(Docker Desktop)에 수집 경로를 올리고 관통까지 확인한다 (#14). ArgoCD 없이 kubectl 로만 넣는 길이다
#
#   ./scripts/up-local.sh            올리기 + 관통 확인
#   ./scripts/up-local.sh --down     지우기 (네임스페이스 셋을 지운다, PVC 도 같이 지워진다)
#
# 쿠버네티스는 넣은 것을 한꺼번에 띄워서 compose 의 depends_on 같은 순서가 없다 (research.md 2.1).
# 그래서 묶음으로 나눠 apply 하고, 사이에서 kubectl wait 로 앞 묶음이 실제로 준비됐는지 기다린다.
# ArgoCD 길(up-argocd.sh)은 같은 순서를 sync wave 로 지킨다. 순서를 바꾸면 이 스크립트와 argocd/apps/local 의 번호표를 둘 다 고친다
#
#   0  네임스페이스 + 비밀값 · SQL · 인증서   local-prereqs.sh
#   1  저장소 셋                  → Ready 까지
#   2  준비 Job 셋                → 성공 종료까지
#   3  수집기 · 적재 처리기        → Ready 까지
#   4  telemetrygen               check-local.sh
#
# 값은 backend .env 와 같은 이름 · 같은 로컬 기본값을 환경변수로 받는다. 레포에는 Secret 이름만 있다 (AGENTS.md §2)
set -euo pipefail
. "$(dirname "$0")/lib.sh"

case "${1:-}" in
  ""|--down) ;;
  *) echo "✗ 모르는 인자 $1 (쓸 수 있는 것 : 없음 · --down)"; exit 1 ;;
esac

require_local_context

if [ "${1:-}" = --down ]; then
  # 지우기는 ALLOW_OTHER_CONTEXT 와 상관없이 로컬에서만 한다 : 다른 클러스터의 data 를 지우면 저장소 볼륨이 같이 간다
  [ "$CONTEXT" = docker-desktop ] || fail "--down 은 docker-desktop 에서만 한다 (지금 $CONTEXT)"
  k delete ns apm data shop --ignore-not-found
  ok "네임스페이스 셋 지움 (로컬 hostpath 는 회수 정책이 Delete 라 볼륨도 같이 지워진다)"
  exit 0
fi

"$ROOT/scripts/local-prereqs.sh"

# ── 1
step "1 저장소 셋"
k apply -k "$ROOT/overlays/local/1-infra" > /dev/null
for s in kafka clickhouse postgres; do wait_rollout data "statefulset/$s"; done

# ── 2
step "2 준비 Job 셋"
rerun_job data kafka-init postgres-migrate clickhouse-migrate
k apply -k "$ROOT/overlays/local/2-jobs" > /dev/null
for j in kafka-init postgres-migrate clickhouse-migrate; do wait_job data "$j"; done

# ── 3
step "3 수집기 · 적재 처리기"
k apply -k "$ROOT/overlays/local/3-apps" > /dev/null
for d in collector ingester; do wait_rollout apm "deployment/$d"; done
# readiness 가 이미 /readyz 를 봤지만, 완료 조건(업무 포트 /readyz 200)을 눈에 보이게 한 번 더 찌른다
for pair in collector:8081 ingester:8082; do
  name=${pair%%:*}; port=${pair##*:}
  code=$(k -n apm exec "deploy/$name" -- bash -c \
    "exec 3<>/dev/tcp/127.0.0.1/$port; printf 'GET /readyz HTTP/1.0\r\n\r\n' >&3; head -1 <&3" | awk '{print $2}') || code="exec 실패"
  [ "$code" = 200 ] && ok "$name :$port/readyz 200" || fail "$name :$port/readyz 가 $code"
done

# ── 4
"$ROOT/scripts/check-local.sh"
