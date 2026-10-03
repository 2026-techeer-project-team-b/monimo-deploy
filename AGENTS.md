# AGENTS.md — 작업을 시작하기 전에 읽는 파일

> **사람이든 AI 도구든, 이 레포에서 무언가를 고치기 전에 이 파일을 먼저 읽는다.**
> 여기에는 레포 구조, 깨면 안 되는 규칙, 지금까지 한 일, 지금 막혀 있는 것이 들어 있다.
>
> 작업을 끝내면 **§5(지금까지 한 일)와 §6(막혀 있는 것)을 갱신해서 같은 PR 에 넣는다.**

## 0. 정본이 어디인가

| 무엇 | 정본 |
|---|---|
| 설계 결정(ADR) | `monimo-backend` 레포 `docs/design/01-decisions.md` |
| 환경변수 이름 | 이 레포 `README.md` 와 `.env.example` |
| PG 마이그레이션 · ClickHouse DDL | Phase 1a 동안은 `monimo-backend` 의 `db/` (1b 부터 이 레포 `schema/`, ADR `#49`) |

## 1. 레포 한눈에

설정 레포다. 여기 적힌 내용이 "클러스터가 이래야 한다"는 정답지이고, Argo CD 가 클러스터를 이 레포에 맞춘다 (GitOps). 애플리케이션 코드는 없다.

Helm · Argo CD · YAML.

| 폴더 | 하는 일 |
|---|---|
| `charts/` | 공통 차트 (서비스용 · 쇼핑몰용) |
| `apps/` | 서비스별 values. **폴더 하나 = 배포 단위 하나** |
| `argocd/` | AppProject · Application |
| `infra/` | Kafka · ClickHouse · PostgreSQL · cert-manager |
| `namespaces/` | shop · apm · data · argocd |
| `schema/` | ClickHouse DDL · PG 마이그레이션 (1b 부터) |
| `compose/` | Phase 1a 단일 노드 docker-compose |

## 2. 깨면 안 되는 규칙

- **비밀값은 레포에 올리지 않는다.** 레포는 퍼블릭이다. compose 는 `.env.example` 에 이름만, 1b 이후 EKS 비밀값은 AWS Secrets Manager 에 두고 values 에는 이름만 적는다.
- **`image.tag` 는 CI 봇이 갱신하는 값이다.** 손으로 바꿀 때는 PR 설명에 이유를 적는다.
- **`apps/` 는 폴더 하나가 배포 단위 하나다.** 한 폴더에 서비스 두 개의 values 를 섞지 않는다.
- **클러스터를 직접 고치지 않는다.** 바꿀 것은 이 레포에 PR 로 올린다. 직접 고친 내용은 Argo CD 가 되돌리거나, 레포와 어긋난 채 남는다.
- **스키마 파일은 1a 동안 여기 두지 않는다.** 같은 파일이 두 레포에 있으면 어느 쪽이 맞는지 알 수 없다.

## 3. 작업 흐름

1. GitHub 이슈를 만든다. 제목은 커밋 형식과 같게.
2. 브랜치를 판다. `feat/<이슈번호>-<설명>` · `fix/<이슈번호>-<설명>` · `chore/<설명>`. **`origin/develop` 에서 새로 판다.**
3. 커밋 메시지는 `<타입>(<범위>): <요약>`. 타입은 feat · fix · docs · chore · refactor · test.
4. PR 의 base 는 `develop`. `main` · `develop` 직접 push 는 막혀 있다.

## 4. 담당

승조 `@SeungJo-02` 단독.

## 5. 지금까지 한 일

- 레포 초기 구성, PR 라벨 자동화와 머지 슬랙 알림 (`#1`)
- `.env.example` — Phase 1a compose 용 이미지 · 인프라 계정 이름 (`#2`)
- CODEOWNERS (`#3`), develop 브랜치 전략 (`#4`), 설계 문서 링크를 `tree/HEAD` 로 (`#5`)
- `AGENTS.md` · `CLAUDE.md`, README 「AI 와 일한 방법」 절, `docs/prompts/`(프롬프트 로그 — 코드와 같은 PR 에). 하네스 정본은 backend `docs/harness/README.md` 한 곳

## 6. 지금 막혀 있는 것

| 무엇 | 안 풀면 |
|---|---|
| 폴더 7개가 전부 비어 있다 (`.gitkeep` 만) | 배포할 수 없다. 서비스는 각자 레포의 compose 로만 뜬다 |
| `compose/` 단일 노드 compose 가 없다 | Phase 1a 를 한 서버에 올릴 방법이 없다 |
| `README.md` 의 로컬 실행 · 포트가 "준비 중"이다 | 위 둘이 생기면 채운다 |

## 7. 참고

- 설계 문서: https://github.com/2026-techeer-project-team-b/monimo-backend/tree/HEAD/docs/design
- 이미지를 만드는 쪽: `monimo-backend` · `monimo-shop` 의 CI
