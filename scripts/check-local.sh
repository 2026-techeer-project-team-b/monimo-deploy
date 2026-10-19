#!/usr/bin/env bash
# 관통 확인 (#20, 예전 up-local.sh 4단계) : telemetrygen → 수집기 → Kafka → 적재 처리기 → ClickHouse
# up-local.sh 는 끝에서 부르고, ArgoCD 길에서는 root sync 가 끝난 뒤 사람이 돌린다.
# ArgoCD hook 으로 안 둔 것은 「보내기 전 줄 수 → 보내기 → 늘었나」를 한 흐름으로 봐야 해서다 (research.md 7절 ③)
set -euo pipefail
. "$(dirname "$0")/lib.sh"

require_local_context

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
