# notion-passport-claude-code

**프로젝트마다 별도의 Notion 워크스페이스를 연결하는 Claude Code 플러그인**

각 작업 디렉터리를 **서로 다른** Notion 워크스페이스에 연결하세요 — "한 계정 = 하나의 공유 워크스페이스" 한계가 사라집니다. 프로젝트마다 고유 이름의 **local-scope** Notion MCP 서버가 생기고, 일반 `/mcp` OAuth 흐름으로 **독립적으로** 인증되므로, Notion 동의 화면에서 프로젝트별로 다른 워크스페이스를 고를 수 있습니다.

---

## 문제

기본 제공되는 Notion MCP 서버는 **서버 항목 단위로** 인증하고, Claude Code는 각 서버의 OAuth 토큰을 **서버 이름**을 키로 삼아 저장합니다. 공식 Notion 플러그인은 단일 공유 `notion` 서버를 user scope에 설치하므로 *모든* 프로젝트가 *하나의* 워크스페이스로 묶입니다. 전환하려면 연결을 끊었다 다시 이어야 하고, 이는 모든 세션에 영향을 줍니다. 프로젝트·세션별 워크스페이스 선택은 [아직 네이티브로 지원되지 않습니다](https://github.com/anthropics/claude-code/issues/45120).

## 해결

**프로젝트마다 서버 이름을 다르게 주면**, 토큰도 워크스페이스도 따로 분리됩니다. 이 플러그인의 `setup-notion-workspace` 스킬이 그 과정을 자동화합니다:

1. 현재 디렉터리에서 **고유 서버 이름**을 도출합니다 (`notion-<dir>-<hash>` — `<hash>`는 절대 경로의 4자리 해시라, 디렉터리 이름이 같은 두 레포가 한 워크스페이스로 합쳐지지 않습니다).
2. **비어 있는 고정 OAuth 콜백 포트**를 고릅니다 (8123부터). 다른 `notion-`* 서버가 이미 쓰는 포트를 미리 스캔해 두 프로젝트가 충돌하지 않도록 합니다.
3. 전역 공유 `notion` 플러그인이 설치돼 있으면 **경고**합니다.
4. 충돌하는 local-scope 서버를 제거한 뒤, 새 서버를 **local scope**에 추가합니다 (`~/.claude.json`, 이 프로젝트 전용).

그다음 `/mcp → Authenticate`를 한 번 실행하고 그 프로젝트의 워크스페이스를 고르면 끝입니다.

## 다른 방법들과의 차이


|               | **notion-passport-claude-code**           | 공식 `notion` 플러그인     | "Notion Pro" 멀티워크스페이스 스킬 |
| ------------- | ----------------------------------------- | -------------------- | ------------------------ |
| 목표            | 프로젝트별 *다른* 워크스페이스 연결 (추후 멀티 워크스페이스 지원 목표) | 어디서나 *하나의* 공유 워크스페이스 | *보조* 워크스페이스 전환           |
| 설정 위치         | **local scope** (`~/.claude.json`)        | user scope (공유)      | `.mcp.json` (레포에 커밋)     |
| 인증            | 호스티드 **OAuth + 고정 콜백 포트**                 | 호스티드 OAuth (단일)      | `.mcp.json` 편집           |
| 다수 프로젝트 확장    | **예** — 고유 이름 + 빈 포트 자동 배정                | 아니오                  | 보조 1개 중심                 |
| 공유 플러그인 충돌 감지 | **예**                                     | —                    | —                        |


각 레포를 자기 워크스페이스에 격리하면서, 커밋되는 설정 없이 표준 OAuth 흐름을 쓰고 싶다면 이 플러그인이 정답입니다.

## 설치

```
/plugin marketplace add notion-passport/notion-passport-claude-code
/plugin install notion-passport@notion-passport
```

> **요구사항:** `claude` CLI(이미 있음)와 PATH 상의 `python3`.

## 사용법

연결하려는 프로젝트에서 다음 중 한 가지 방법으로 Notion 워크스페이스를 연결합니다.

- **슬래시 명령** — `/setup-notion-workspace` 를 실행합니다.
- **자연어로 요청** — Claude Code에게 "이 레포에 노션 워크스페이스 붙여줘" / "connect this project to Notion" 처럼 말하면 스킬이 자동으로 트리거됩니다.

### 실행 후 (대화형 — 직접 해야 하는 단계)

1. 전역 플러그인을 방금 제거했다면 **Claude Code 재시작**.
2. `/mcp` → 새 서버 선택 → **Authenticate**.
3. 브라우저에서 이 mcp와 **연결할 Notion 워크스페이스**를 선택.

### 권장 일회성 정리

가장 깔끔한 프로젝트별 설정을 원하면, 공유 전역 플러그인을 한 번 제거하세요 (전역 변경이며 해당 플러그인의 스킬도 함께 제거됩니다):

```bash
claude plugin uninstall notion@claude-plugins-official
```

## Repo 구조

```
notion-passport-claude-code/
├── .claude-plugin/marketplace.json     # 마켓플레이스 카탈로그
└── plugins/
    └── notion-passport-claude-code/
        ├── .claude-plugin/plugin.json  # 플러그인 매니페스트
        └── skills/
            └── setup-notion-workspace/
                ├── SKILL.md
                └── scripts/setup_notion_workspace.py
```

## 라이선스

MIT — [LICENSE](./LICENSE) 참고.