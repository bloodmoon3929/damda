# 담다

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
| Windows | `damda-<버전>-windows.zip` | 압축을 풀고 `notes.exe` 실행 |
| macOS | `damda-<버전>-macos.zip` | 압축을 풀고 `Damda.app`을 응용 프로그램 폴더로. 서명되지 않은 앱이라 처음 한 번은 우클릭 → 열기(또는 `xattr -dr com.apple.quarantine /Applications/Damda.app`) |
| Linux | `damda-<버전>-linux-x64.tar.gz` | 압축을 풀고 `notes` 실행. `libmpv`, `libsecret`, `libgtk-3`가 필요합니다 (Ubuntu: `sudo apt install libmpv2 libsecret-1-0 libgtk-3-0`) |
| Android | `damda-<버전>-android-arm64.apk` | 설치 |

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
