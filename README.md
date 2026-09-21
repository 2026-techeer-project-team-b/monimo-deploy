# monimo-deploy

설정 레포(GitOps 정답지): Helm 차트 · 환경별 values · Argo CD Application · 스키마 · Phase 1a compose

- 기술: Helm · Argo CD · YAML
- 상태: 뼈대만 있음 (개발환경 세팅 중)

## 폴더 구성

| 폴더 | 하는 일 |
|---|---|
| `charts/` | 공통 차트 (서비스용 · 쇼핑몰용) |
| `apps/` | 서비스별 values. 폴더 하나 = 배포 단위 하나 |
| `argocd/` | AppProject · Application |
| `infra/` | Kafka · ClickHouse · PostgreSQL · cert-manager |
| `namespaces/` | shop · apm · data · argocd |
| `schema/` | ClickHouse DDL · PG 마이그레이션 (1b부터, 1a 동안은 backend에 둠) |
| `compose/` | Phase 1a 단일 노드 docker-compose |

## 로컬 실행

준비 중

## 환경변수

실제 값은 레포에 올리지 않는다. `.env.example` 에 이름만 적는다.

| 이름 | 설명 |
|---|---|
| (준비 중) | |

## 포트

| 서비스 | 포트 |
|---|---|
| (준비 중) | |

## 관련 문서

- [설계 문서 (결정 기록 원본)](https://github.com/2026-techeer-project-team-b/monimo-backend/tree/main/docs/design): monimo-backend 레포의 `docs/design/`
- [레포별 파일 구성](https://app.notion.com/p/3e1d7d6851ff80a8a110e8aea0b5783b)
- [깃허브 레포지토리 규칙](https://app.notion.com/p/3dcd7d6851ff8000b795f1cc609124e6)

## 기여 규칙

- `main` 직접 push 금지, PR로만 머지
- 브랜치: `feat/<이슈번호>-<설명>` · `fix/<이슈번호>-<설명>` · `chore/<설명>`
- 커밋: `<타입>(<범위>): <요약>` (타입: feat · fix · docs · chore · refactor · test)
