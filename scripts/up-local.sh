#!/usr/bin/env bash
# 로컬 쿠버네티스(Docker Desktop)에 수집 경로를 올리고 관통까지 확인한다 (#14).
#
#   ./scripts/up-local.sh            올리기 + 관통 확인
#   ./scripts/up-local.sh --down     지우기 (네임스페이스 셋을 지운다, PVC 도 같이 지워진다)
#
# 쿠버네티스는 넣은 것을 한꺼번에 띄워서 compose 의 depends_on 같은 순서가 없다 (research.md 2.1).
# 그래서 묶음으로 나눠 apply 하고, 사이에서 kubectl wait 로 앞 묶음이 실제로 준비됐는지 기다린다.
# 순서를 손으로 시작한다는 ADR #66 ① 의 "손" 을 한 줄로 묶은 것이다. 배포 도구가 서면 sync wave 로 옮기고 이 스크립트는 버린다.
#
#   0  네임스페이스 + 비밀값 · SQL · 인증서 (레포에 안 두는 것을 여기서 넣는다)
#   1  저장소 셋                  → Ready 까지
#   2  준비 Job 셋                → 성공 종료까지
#   3  수집기 · 적재 처리기        → Ready 까지
#   4  telemetrygen               → ClickHouse spans · metrics_raw · logs 줄 수가 늘었나
#
# 값은 backend .env 와 같은 이름 · 같은 로컬 기본값을 환경변수로 받는다. 레포에는 Secret 이름만 있다 (AGENTS.md §2)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BACKEND_DIR=${BACKEND_DIR:-$ROOT/../monimo-backend}
CONTEXT=${KUBE_CONTEXT:-docker-desktop}
WAIT_SECONDS=${WAIT_SECONDS:-300}
TIMEOUT=${WAIT_SECONDS}s
CHECK_WAIT_SECONDS=${CHECK_WAIT_SECONDS:-60}

case "${1:-}" in
  ""|--down) ;;
  *) echo "✗ 모르는 인자 $1 (쓸 수 있는 것 : 없음 · --down)"; exit 1 ;;
esac

# 아래 기본값은 backend compose.yaml 과 같은 공개 로컬 기본값이다 (로컬 전용, 운영 값이 아니다).
# 바꾸면 이미 떠 있는 파드와 PG 볼륨(처음 만들 때의 비밀번호를 기억한다)에는 안 들어간다 : --down 뒤에 다시 올린다
POSTGRES_USER=${POSTGRES_USER:-monimo}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-monimo}
CLICKHOUSE_USER=${CLICKHOUSE_USER:-monimo}
CLICKHOUSE_PASSWORD=${CLICKHOUSE_PASSWORD:-monimo}
MONIMO_AGENT_TOKEN=${MONIMO_AGENT_TOKEN:-local-agent-token}
MONIMO_INTERNAL_TOKEN=${MONIMO_INTERNAL_TOKEN:-local-internal-token}

ok()   { echo "✓ $1"; }
step() { echo; echo "── $1"; }
fail() { echo "✗ $1"; exit 1; }

k() { kubectl --context "$CONTEXT" "$@"; }

# 앞 묶음이 제한 시간 안에 안 서면 여기서 멈추고 원인을 보여 준다
wait_rollout() {   # $1 = 네임스페이스, $2 = 종류/이름
  k -n "$1" rollout status "$2" --timeout="$TIMEOUT" > /dev/null \
    && ok "$2 Ready" \
    || { k -n "$1" describe "$2" | tail -20; fail "$2 가 $TIMEOUT 안에 Ready 가 안 됐다 (kubectl -n $1 get pods · logs 로 본다)"; }
}
# kubectl wait --for=condition=complete 는 Job 이 이미 실패해도 제한 시간 끝까지 기다린다. 성공 · 실패를 둘 다 보며 기다린다
wait_job() {       # $1 = 네임스페이스, $2 = Job 이름
  local deadline=$((SECONDS + WAIT_SECONDS)) state
  while [ "$SECONDS" -lt "$deadline" ]; do
    state=$(k -n "$1" get "job/$2" -o jsonpath='{.status.succeeded}/{.status.failed}' 2> /dev/null) || state=/
    case "$state" in
      [1-9]*/*) ok "job/$2 성공 종료"; return 0 ;;
    esac
    # 실패가 backoffLimit 을 넘으면 Failed 조건이 붙는다. 그 전의 실패는 쿠버네티스가 다시 돌리니 기다린다
    if [ "$(k -n "$1" get "job/$2" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2> /dev/null)" = True ]; then
      k -n "$1" logs "job/$2" --all-containers --tail=30 || true
      fail "job/$2 실패 (재시도 한도까지 다 썼다). 위 로그를 본다"
    fi
    sleep 2
  done
  k -n "$1" logs "job/$2" --all-containers --tail=30 || true
  fail "job/$2 가 $TIMEOUT 안에 끝나지 않았다"
}
# Job 은 내용을 고칠 수 없어서 다시 돌릴 때는 지우고 새로 만든다
rerun_job() {      # $1 = 네임스페이스, 나머지 = Job 이름
  local ns=$1; shift
  k -n "$ns" delete job "$@" --ignore-not-found --wait=true > /dev/null
}

# ConfigMap 은 server-side apply 로 넣는다 : 일반 apply 는 내용 전체를 주석에 한 번 더 적어 크기 한도(256 KiB)에 먼저 걸린다
apply_from_files() {   # $1 = 네임스페이스, $2 = ConfigMap 이름, $3 = 폴더 (그 아래 V*.sql 전부, 하위 폴더 포함)
  local args=() f
  while IFS= read -r f; do args+=("--from-file=$f"); done < <(find "$3" -name 'V*.sql' -type f | sort)
  [ ${#args[@]} -gt 0 ] || fail "$3 에 V*.sql 이 없다"
  k -n "$1" create configmap "$2" "${args[@]}" --dry-run=client -o yaml \
    | k apply --server-side --force-conflicts -f - > /dev/null
  ok "ConfigMap $2 : 파일 ${#args[@]}개 ($3)"
}

# ── 준비
[ "$(kubectl config get-contexts -o name | grep -cxF "$CONTEXT")" = 1 ] || fail "컨텍스트 $CONTEXT 가 없다"
# 남의 클러스터(EKS 등)에 넣지 않게 : 이 스크립트는 로컬 전용이다
[ "$CONTEXT" = docker-desktop ] || [ "${ALLOW_OTHER_CONTEXT:-}" = 1 ] \
  || fail "로컬 전용 스크립트다. 컨텍스트가 $CONTEXT (docker-desktop 이 아니면 ALLOW_OTHER_CONTEXT=1)"

if [ "${1:-}" = --down ]; then
  # 지우기는 ALLOW_OTHER_CONTEXT 와 상관없이 로컬에서만 한다 : 다른 클러스터의 data 를 지우면 저장소 볼륨이 같이 간다
  [ "$CONTEXT" = docker-desktop ] || fail "--down 은 docker-desktop 에서만 한다 (지금 $CONTEXT)"
  k delete ns apm data shop --ignore-not-found
  ok "네임스페이스 셋 지움 (로컬 hostpath 는 회수 정책이 Delete 라 볼륨도 같이 지워진다)"
  exit 0
fi

step "준비"
k get nodes > /dev/null 2>&1 || fail "클러스터에 닿지 않는다 (Docker Desktop 설정 → Kubernetes 켜기)"
ok "클러스터 $CONTEXT"
for image in monimo/collector:dev monimo/ingester:dev monimo/clickhouse-migrate:dev monimo/otlp-certs:dev; do
  docker image inspect "$image" > /dev/null 2>&1 \
    || fail "이미지 $image 가 없다. backend 에서 docker compose --profile collector --profile ingester build 로 만든다"
done
ok "로컬 이미지 넷 (monimo/*:dev)"
[ -d "$BACKEND_DIR/db/postgres" ] && [ -d "$BACKEND_DIR/db/clickhouse" ] \
  || fail "backend 레포를 못 찾았다 : $BACKEND_DIR (BACKEND_DIR=... 로 알려 준다)"
ok "backend 레포 $BACKEND_DIR"

# ── 0
step "0 네임스페이스 · 비밀값 · SQL · 인증서"
k apply -k "$ROOT/overlays/local/0-namespaces" > /dev/null
ok "네임스페이스 data · apm · shop"

for ns in data apm; do
  k -n "$ns" create secret generic monimo-db \
    --from-literal=POSTGRES_USER="$POSTGRES_USER" --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
    --from-literal=CLICKHOUSE_USER="$CLICKHOUSE_USER" --from-literal=CLICKHOUSE_PASSWORD="$CLICKHOUSE_PASSWORD" \
    --dry-run=client -o yaml | k apply -f - > /dev/null
done
k -n apm create secret generic monimo-tokens \
  --from-literal=MONIMO_AGENT_TOKEN="$MONIMO_AGENT_TOKEN" --from-literal=MONIMO_INTERNAL_TOKEN="$MONIMO_INTERNAL_TOKEN" \
  --dry-run=client -o yaml | k apply -f - > /dev/null
ok "Secret monimo-db (data · apm) · monimo-tokens (apm)"

# 마이그레이션 SQL 은 이 레포에 두지 않는다 (AGENTS.md §2). backend 의 지금 작업 폴더를 그대로 읽는다
apply_from_files data pg-migrations "$BACKEND_DIR/db/postgres"
apply_from_files data ch-migrations "$BACKEND_DIR/db/clickhouse"

# 인증서 : compose 의 otlp-certs 와 같은 이미지 · 같은 폴더(backend certs/)를 쓴다. 없으면 만들고 있으면 아무것도 안 한다.
# 같은 폴더라 compose 쪽 쇼핑몰이 믿는 기관과 같다. 수집기에는 셋(ca · server)만 Secret 으로 건다
docker run --rm -v "$BACKEND_DIR/certs:/certs" monimo/otlp-certs:dev > /dev/null
k -n apm create secret generic otlp-certs-collector \
  --from-file=ca.crt="$BACKEND_DIR/certs/ca.crt" \
  --from-file=server.crt="$BACKEND_DIR/certs/server.crt" \
  --from-file=server.key="$BACKEND_DIR/certs/server.key" \
  --dry-run=client -o yaml | k apply -f - > /dev/null
ok "Secret otlp-certs-collector (TLS 는 기본 꺼짐, 켜는 법은 README)"

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
step "4 관통 확인 (telemetrygen → 수집기 → Kafka → 적재 처리기 → ClickHouse)"
ch() {   # ClickHouse 파드 안에서 쿼리 한 줄. 계정은 파드 환경변수를 쓴다
  k -n data exec clickhouse-0 -- sh -c "clickhouse-client --user \"\$CLICKHOUSE_USER\" --password \"\$CLICKHOUSE_PASSWORD\" --query \"$1\""
}
# telemetrygen 이 보낸 줄만 센다. 수집기 · 적재 처리기 자신의 에이전트도 같은 수집기로 지표 · 로그를 보내서(자기 감시, backend #208)
# 전체 줄 수로 보면 telemetrygen 이 실패해도 늘어난다 (2026-10-17 첫 실행 : logs 108줄 중 telemetrygen 3줄)
count() { ch "SELECT count() FROM monimo.$1 WHERE service_name = 'telemetrygen'"; }

# macOS 기본 bash 3.2 에는 연관 배열이 없어 before_<표> 변수로 둔다
for t in spans metrics_raw logs; do
  n=$(count "$t") || fail "monimo.$t 를 못 읽었다 (clickhouse-migrate 가 표를 만들었나)"
  printf -v "before_$t" '%s' "$n"
done

rerun_job apm telemetrygen
k apply -k "$ROOT/overlays/local/4-checks" > /dev/null
wait_job apm telemetrygen

for t in spans metrics_raw logs; do
  var="before_$t"; was=${!var}; now=$was
  deadline=$((SECONDS + CHECK_WAIT_SECONDS))
  while [ "$SECONDS" -lt "$deadline" ]; do
    now=$(count "$t") || now=$was   # 한 번 못 읽은 것은 다시 시도한다 (여기서 멈추면 원인 없이 끝난다)
    [ "$now" -gt "$was" ] && break
    sleep 1
  done
  [ "$now" -gt "$was" ] \
    && ok "monimo.$t $was → $now" \
    || fail "monimo.$t 가 ${CHECK_WAIT_SECONDS}초 안에 안 늘었다 ($was). kubectl -n apm logs deploy/collector · deploy/ingester 를 본다"
done

echo
ok "로컬 쿠버네티스 수집 경로 관통 (agents 는 안 본다 : telemetrygen 서비스는 등록돼 있지 않다, backend #66)"
