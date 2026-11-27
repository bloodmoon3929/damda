# 나무

**나**날이 **무**성해지는 노트. 적을수록 페이지가 가지를 뻗고, 링크로 이어지며 우거집니다.

개인용 노트 앱입니다. 노션처럼 블록 편집기와 데이터베이스를, 옵시디언처럼 링크와 그래프를 쓰고, 직접 운영하는 서버로 기기끼리 동기화합니다.

- 블록 편집기: 마크다운 단축 입력, 토글·콜아웃, 수식, 코드, 표, 페이지 링크(`[[`)
- 데이터베이스: 표·보드·캘린더·갤러리·지도, 수식(let, 메서드 체인)
- 계획 지도: 카드와 화살표로 하위 계획을 잇고 메모·체크리스트·진행 상황을 관리
- 사진 보관함: 아래 노트의 사진을 페이지별 탭으로 모아 보기, 다운로드
- 그래프, 백링크, 검색(퍼지 검색, `path:` `task:` 등)
- Windows · macOS · Linux · Android

## 내려받기

[Releases](../../releases/latest)에서 기기에 맞는 파일을 받으세요. 새 버전이 나오면 앱이 알려 줍니다.

| 기기 | 파일 | 설치 |
|---|---|---|
| Windows | `namu-<버전>-windows.zip` | 압축을 풀고 `notes.exe` 실행 |
| macOS | `namu-<버전>-macos.zip` | 압축을 풀고 `Namu.app`을 응용 프로그램 폴더로. 아래 [macOS에서 처음 열기](#macos에서-처음-열기) 참고 |
| Linux | `namu-<버전>-linux-x64.tar.gz` | 압축을 풀고 `notes` 실행. `libmpv`, `libsecret`, `libgtk-3`가 필요합니다 (Ubuntu: `sudo apt install libmpv2 libsecret-1-0 libgtk-3-0`) |
| Android | `namu-<버전>-android-arm64.apk` | 설치 |

### macOS에서 처음 열기

Apple 개발자 서명·공증을 받지 않은 앱이라, 처음 열면 "악성 코드가 없음을 확인할 수 없습니다"라고 막힙니다. 한 번만 허용하면 됩니다.

- 시스템 설정 → 개인정보 보호 및 보안 → 아래쪽 "Namu이(가) 차단되었습니다" 옆 **그래도 열기** (macOS 15부터는 우클릭 → 열기로는 안 됩니다)
- 또는 터미널에서 `xattr -dr com.apple.quarantine /Applications/Namu.app`

새 버전으로 바꾼 뒤 Notion 가져오기에서 저장해 둔 토큰을 읽을 때 키체인 접근을 물으면 "항상 허용"을 누르세요.

## 구성

- `app/`: Flutter 앱
- `server/`: 동기화 서버 (FastAPI, Docker). `server/.env.example`을 `.env`로 복사하고 관리자 토큰을 정해서 실행합니다.
- `packages/`: 고쳐 쓰는 라이브러리 (`appflowy_editor` 등, 고친 곳은 `PATCH(notes #번호)`)

## 빌드

Flutter 3.47 기준입니다.

```
cd app
flutter pub get
flutter run -d windows   # macos, linux, android
```

릴리스는 `v1.2.3` 같은 태그를 올리면 GitHub Actions가 Windows·macOS·Linux를 빌드해 Releases에 올립니다(`.github/workflows/release.yml`).
