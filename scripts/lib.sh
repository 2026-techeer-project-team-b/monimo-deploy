# 로컬 스크립트들이 같이 쓰는 값과 함수 (#20). 혼자 돌리지 않고 source 로 불러 쓴다
#   up-local.sh · up-argocd.sh · local-prereqs.sh · check-local.sh

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BACKEND_DIR=${BACKEND_DIR:-$ROOT/../monimo-backend}
CONTEXT=${KUBE_CONTEXT:-docker-desktop}
WAIT_SECONDS=${WAIT_SECONDS:-300}
TIMEOUT=${WAIT_SECONDS}s
CHECK_WAIT_SECONDS=${CHECK_WAIT_SECONDS:-60}

ok()   { echo "✓ $1"; }
step() { echo; echo "── $1"; }
fail() { echo "✗ $1"; exit 1; }

k() { kubectl --context "$CONTEXT" "$@"; }

# 남의 클러스터(EKS 등)에 넣지 않게 : 이 스크립트들은 로컬 전용이다
require_local_context() {
  [ "$(kubectl config get-contexts -o name | grep -cxF "$CONTEXT")" = 1 ] || fail "컨텍스트 $CONTEXT 가 없다"
  [ "$CONTEXT" = docker-desktop ] || [ "${ALLOW_OTHER_CONTEXT:-}" = 1 ] \
    || fail "로컬 전용 스크립트다. 컨텍스트가 $CONTEXT (docker-desktop 이 아니면 ALLOW_OTHER_CONTEXT=1)"
}

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
