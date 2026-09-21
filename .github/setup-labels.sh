#!/usr/bin/env bash
# PR 라벨 워크플로가 쓰는 라벨을 이 레포에 한 번에 만든다. 이미 있으면 색상 · 설명만 갱신한다.
# 실행: ./.github/setup-labels.sh   (gh auth login 필요)
set -euo pipefail

# 이름:색상(hex, # 없이):설명
LABELS=(
  "type/feature:0E8A16:새 기능 추가"
  "type/bug:D73A4A:버그 / 오류"
  "type/refactor:FBCA04:리팩토링 (동작 변경 없음)"
  "type/docs:0075CA:문서"
  "type/test:BFD4F2:테스트"
  "type/chore:CFD3D7:빌드/설정/잡일"
  "type/ci:CFD3D7:CI / 배포"
  "type/style:E4E669:코드 스타일 (포맷)"
  "type/perf:5319E7:성능 개선"
  "size/XS:3CBF00:변경 <10줄"
  "size/S:5FE800:변경 <50줄"
  "size/M:FBCA04:변경 <200줄"
  "size/L:FF9F00:변경 <500줄"
  "size/XL:E11D21:변경 ≥500줄"
  "area/charts:C5DEF5:Helm 차트"
  "area/apps:C5DEF5:서비스별 values"
  "area/argocd:C5DEF5:Argo CD"
  "area/infra:FEF2C0:Kafka · ClickHouse · PostgreSQL · cert-manager"
  "area/namespaces:C5DEF5:네임스페이스"
  "area/schema:1D76DB:DB 스키마 · 마이그레이션"
  "area/compose:FEF2C0:Phase 1a compose"
  "area/ci:CFD3D7:CI · GitHub 설정"
  "area/docs:0075CA:문서"
)

for entry in "${LABELS[@]}"; do
  IFS=":" read -r name color desc <<< "$entry"
  if gh label create "$name" --color "$color" --description "$desc" --force >/dev/null 2>&1; then
    echo "✓ $name"
  else
    echo "✗ $name (실패)"
  fi
done
