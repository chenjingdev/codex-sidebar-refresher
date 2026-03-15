# codex-sidebar-refresher

Codex Desktop App 사이드바 노출을 정리하는 로컬 도구 모음입니다.

## 왜 쓰나

다음 같은 상황에서 씁니다.

- Codex CLI에서는 예전 채팅이 보이는데 Desktop App 사이드바에서는 안 보일 때
- 특정 workspace 안에 채팅이 더 있어야 하는데 App에는 일부만 보일 때
- pin하면 보였다가 다시 사라지는 식으로 recent 목록이 불안정할 때

## 왜 이런 현상이 생기나

현재 분석한 Codex Desktop App 구현 기준으로, 사이드바는 workspace 전체 히스토리를 그대로 보여주지 않고 저장된 workspace root와 최근 스레드 일부를 조합해서 목록을 만듭니다.

그래서 오래된 스레드가 local DB에 남아 있어도 recent 범위 밖이면 App 사이드바에서 빠질 수 있습니다.

## recent 범위에 대해

현재 분석한 앱 번들 기준으로 Desktop App은 시작할 때 `thread/list(limit=50, sortKey=updated_at)` 형태로 최근 스레드 50개를 먼저 읽습니다.

그래서 특정 workspace의 스레드가 DB에는 남아 있어도:

- global recent 순위가 너무 뒤에 있으면
- App startup 시 로드 대상에 못 들어가고
- 결과적으로 사이드바에서도 안 보일 수 있습니다.

공개 API 계약이 아니라 앱 내부 구현값이므로, 향후 버전에서는 바뀔 수 있습니다.

## Codex가 로컬에서 세션을 관리하는 방식

이 도구가 기대하는 로컬 저장 구조는 대략 이렇습니다.

- `~/.codex/state_5.sqlite`
  - 스레드 메타데이터를 담는 SQLite DB입니다.
  - 이 도구는 여기서 `threads` 테이블의 `id`, `cwd`, `title`, `updated_at`, `source` 를 기준으로 동작합니다.
- `~/.codex/sessions/.../*.jsonl`
  - 실제 대화 이벤트 로그가 들어 있는 세션 파일입니다.
  - 보통 대화 본문은 여기 남아 있습니다.
- `~/.codex/.codex-global-state.json`
  - Desktop App 사이드바가 참고하는 workspace root 목록과 UI 상태가 들어 있습니다.
  - 특히 `electron-saved-workspace-roots` 가 이 도구의 기본 입력입니다.

즉, 로컬에서 보면:

- `sessions/*.jsonl` = 대화 로그
- `state_5.sqlite` = 스레드 메타데이터와 정렬 기준
- `.codex-global-state.json` = 앱 사이드바가 참고하는 root 목록

이 도구는 이 중에서 `state_5.sqlite` 와 `.codex-global-state.json` 만 읽고, 실제 대화 본문이 들어 있는 `sessions/*.jsonl` 은 수정하지 않습니다.

## 어떻게 동작하나

`refresh-visible-workspaces.sh` 는 다음 순서로 동작합니다.

1. `electron-saved-workspace-roots` 를 읽어 현재 사이드바 기준 workspace 목록을 잡습니다.
2. 각 root와 `cwd`가 정확히 일치하는 direct thread만 고릅니다.
3. `exec` 와 subagent thread는 제외합니다.
4. 이미 pin된 thread는 제외합니다.
5. 선택된 thread의 `updated_at` 을 더 최근 값으로 갱신해 recent 상단으로 보냅니다.
6. Codex App을 다시 시작해서 바뀐 recent 순서가 바로 반영되게 합니다.

즉 이 도구는:

- `sessions/*.jsonl` 안의 대화 본문은 건드리지 않고
- `state_5.sqlite` 안 `threads.updated_at` 정렬만 조정해서
- App이 먼저 읽는 recent 집합 안으로 원하는 스레드를 다시 올리는 방식입니다.

그래서 "대화가 복구됐다"기보다는, "이미 남아 있던 스레드를 App이 다시 보게 만든다"에 가깝습니다.

## 포함 스크립트

- `scripts/refresh-visible-workspaces.sh`
  - 저장된 workspace root 기준으로 direct thread의 `updated_at`을 더 최근 값으로 갱신합니다.
  - 실행 시 Codex App을 종료 확인창 없이 다시 시작합니다.

## 요구사항

- macOS
- 로컬 Codex App 설치
- 로컬 Codex 데이터 디렉터리
  - 기본값: `~/.codex`
- `sqlite3`
- `/usr/bin/python3`

## 환경변수

- `CODEX_HOME`
  - 기본값: `~/.codex`
- `CODEX_APP_PATH`
  - 기본값: `/Applications/Codex.app`
- `CODEX_APP_CMD`
  - 기본값: `$CODEX_APP_PATH/Contents/MacOS/Codex`
- `CODEX_APP_PROCESS_NAME`
  - 기본값: `Codex`

## 주의사항

- `refresh-visible-workspaces.sh` 실행 시 Codex App이 종료 확인창 없이 꺼졌다가 다시 켜집니다.
- 일반 터미널에서 실행하는 편이 안전합니다.
- 모든 변경 전에 자동 백업을 만듭니다.
- `refresh-visible-workspaces.sh` 는 실제 `updated_at` 값을 더 최근으로 갱신합니다.
- 대화 내용은 수정하지 않지만, 스레드의 recent 정렬 순서는 바뀝니다.
- 이미 pin된 스레드는 승격 대상과 개수 계산에서 제외됩니다.
- 향후 Codex App 내부 구현이 바뀌면 이 방식이 덜 잘 맞을 수 있습니다.

## 사용법

### 1. 현재 사이드바에 저장된 workspace별로 최근 스레드 몇 개씩 승격

```bash
./scripts/refresh-visible-workspaces.sh --threads-per-root 3
```

### 2. 현재 사이드바에 저장된 workspace 전체를 풀로 보고, 시간순 상위 50개만 승격

```bash
./scripts/refresh-visible-workspaces.sh --total-threads 50
```

기본값은 `electron-saved-workspace-roots` 기준이고, 이 값이 비어 있으면 `active-workspace-roots`로 fallback합니다.
명령 실행 시 Codex App은 자동으로 재시작됩니다.

### 3. 특정 root만 승격

```bash
./scripts/refresh-visible-workspaces.sh \
  --only-root /absolute/path/to/project \
  --threads-per-root 5
```

예시:

```bash
./scripts/refresh-visible-workspaces.sh \
  --only-root /Users/chenjing/dev/project \
  --threads-per-root 5
```

## 동작 방식

`refresh-visible-workspaces.sh`

- `electron-saved-workspace-roots` 또는 `--only-root` 목록을 읽음
- 해당 root와 `cwd`가 정확히 일치하는 direct thread만 고름
- `exec`와 subagent thread는 제외
- pin된 thread는 제외
- 선택된 thread의 `updated_at`을 더 최근 값으로 갱신함
- 앱 상태 파일은 건드리지 않음
