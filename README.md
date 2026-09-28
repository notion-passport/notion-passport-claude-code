# notion-passport-claude-code

**한 프로젝트에 여러 Notion 계정·워크스페이스를 연결하는 Claude Code 플러그인**

프로젝트마다 Notion 연결을 분리하고, 같은 프로젝트에도 여러 워크스페이스를 등록할 수 있습니다. 연결 별칭은 디렉터리 이름과 랜덤 문자열을 조합해 자동으로 생성합니다.

## 기능

- 프로젝트별 독립 연결 및 한 프로젝트의 다중 연결 지원
- 연결마다 공식 Notion MCP의 OAuth로 개별 인증
- 연결을 이 디렉터리의 local scope에만 등록하므로 레포에 커밋되는 설정 없음
- 연결 추가·목록 조회·기본 연결 지정·삭제, 이전 버전 연결 이어받기
- 연결 별칭 또는 기본 연결에 맞춰 Notion 도구 선택
- 별도 런타임이나 패키지 설치 없이 기본 셸 명령으로 실행

## 설치

> **요구사항:** macOS 또는 Linux, PATH에 등록된 Claude Code CLI(`claude`).

Claude Code에서 실행합니다.

```
/plugin marketplace add notion-passport/notion-passport-claude-code
/plugin install notion-passport@notion-passport
```

## 사용법

Claude Code에서 자연어로 요청하거나 스킬을 지정합니다.

```text
이 프로젝트에 노션 워크스페이스를 연결해줘.
이 프로젝트에 다른 노션 워크스페이스도 추가해줘.
이 프로젝트의 노션 연결 목록을 보여줘.
```

연결 설정에는 `/setup-notion-workspace`, 연결을 지정한 Notion 작업에는 `/use-notion-workspace`를 사용합니다.

별칭은 `my-project-a1b2c3d4` 같은 형태로 자동 생성되고, 연결마다 `notion-my-project-a1b2c3d4` MCP 서버가 추가됩니다. `/mcp`에서 새 서버를 골라 **Authenticate**를 누르고, 브라우저에서 이 연결에 쓸 Notion 계정과 워크스페이스를 선택하세요.

연결한 워크스페이스를 지정해 작업할 수 있습니다.

```text
my-project-a1b2c3d4 연결에서 작업 문서를 찾아줘.
my-project-a1b2c3d4를 기본 노션 연결로 설정해줘.
```

연결을 제거하면 해당 프로젝트의 서버 설정만 지우고, OAuth 인증 정보는 남겨 둡니다.

### 0.0.x에서 업그레이드

이전 버전이 만든 서버(`notion-<디렉터리>-<4자리>`)는 그대로 동작하지만, 이어받기 전에는 연결 목록에 나오지 않습니다. 해당 프로젝트에서 "기존 노션 연결을 이어받아줘"라고 요청하면, 다시 인증하지 않고 연결 목록에 등록합니다.

## 동작 방식

Claude Code는 MCP 서버의 OAuth 토큰을 서버 이름별로 저장합니다. 그래서 연결마다 이름이 다른 서버를 두면 인증도 따로 되고, 워크스페이스도 따로 고를 수 있습니다.

- 서버는 `claude mcp add --scope local`로만 추가·제거합니다. 설정은 `~/.claude.json`의 이 디렉터리 항목에 저장되고, 레포에는 아무것도 쓰지 않습니다.
- 서버마다 고정 OAuth 콜백 포트를 씁니다. 8123부터, 다른 서버가 쓰지 않는 가장 낮은 포트를 고릅니다.
- 연결 목록과 기본 연결은 `~/.claude/notion-passport/projects/`에 디렉터리별로 저장합니다.
- 공유 `notion` 플러그인이나 claude.ai Notion 커넥터와 함께 써도 됩니다. `/use-notion-workspace`는 고른 연결의 도구만 사용합니다.

## Repo 구조

```
notion-passport-claude-code/
├── .claude-plugin/marketplace.json     # 마켓플레이스 카탈로그
├── plugins/
│   └── notion-passport-claude-code/
│       ├── .claude-plugin/plugin.json  # 플러그인 매니페스트
│       ├── scripts/notion-passport.sh  # 연결 관리 스크립트
│       └── skills/
│           ├── setup-notion-workspace/SKILL.md
│           └── use-notion-workspace/SKILL.md
└── tests/test-notion-passport.sh       # 스크립트 테스트 (sh tests/test-notion-passport.sh)
```

## 라이선스

MIT — [LICENSE](./LICENSE) 참고.
