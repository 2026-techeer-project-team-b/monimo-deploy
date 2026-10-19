#!/usr/bin/env bash
# 레포에 안 두는 것을 로컬 클러스터에 넣는다 (#20, 예전 up-local.sh 0단계).
# up-local.sh 와 up-argocd.sh 가 둘 다 이것부터 부른다. 다시 돌려도 안전하다 (전부 apply)
#
#   네임스페이스 data · apm · shop
#   Secret monimo-db (data · apm) · monimo-tokens (apm)       비밀값 : 레포에는 이름만 (AGENTS.md §2)
#   ConfigMap pg-migrations · ch-migrations (data)            SQL : backend db/ 를 그대로 읽는다 (AGENTS.md §2)
#   Secret otlp-certs-collector (apm)                         인증서 : backend certs/ (compose 와 같은 폴더)
#
# ArgoCD 길에서는 네임스페이스를 0-namespaces 자식도 넣는다. 여기서 먼저 넣는 것은 Secret 을 담을 곳이 있어야 해서다
set -euo pipefail
. "$(dirname "$0")/lib.sh"

# 아래 기본값은 backend compose.yaml 과 같은 공개 로컬 기본값이다 (로컬 전용, 운영 값이 아니다).
# 바꾸면 이미 떠 있는 파드와 PG 볼륨(처음 만들 때의 비밀번호를 기억한다)에는 안 들어간다 : --down 뒤에 다시 올린다
POSTGRES_USER=${POSTGRES_USER:-monimo}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-monimo}
CLICKHOUSE_USER=${CLICKHOUSE_USER:-monimo}
CLICKHOUSE_PASSWORD=${CLICKHOUSE_PASSWORD:-monimo}
MONIMO_AGENT_TOKEN=${MONIMO_AGENT_TOKEN:-local-agent-token}
MONIMO_INTERNAL_TOKEN=${MONIMO_INTERNAL_TOKEN:-local-internal-token}

# ConfigMap 은 server-side apply 로 넣는다 : 일반 apply 는 내용 전체를 주석에 한 번 더 적어 크기 한도(256 KiB)에 먼저 걸린다
apply_from_files() {   # $1 = 네임스페이스, $2 = ConfigMap 이름, $3 = 폴더 (그 아래 V*.sql 전부, 하위 폴더 포함)
  local args=() f
  while IFS= read -r f; do args+=("--from-file=$f"); done < <(find "$3" -name 'V*.sql' -type f | sort)
  [ ${#args[@]} -gt 0 ] || fail "$3 에 V*.sql 이 없다"
  k -n "$1" create configmap "$2" "${args[@]}" --dry-run=client -o yaml \
    | k apply --server-side --force-conflicts -f - > /dev/null
  ok "ConfigMap $2 : 파일 ${#args[@]}개 ($3)"
}

require_local_context

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
