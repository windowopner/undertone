# Undertone v1.0

바탕화면에 깔리는 음악 반응 배경 + 켤 때 Verci·Lumn 자동 실행.

## 설치

```bash
cd ~/Codes/Undertone2
./build.sh
```

- `swiftc 없음`이 뜨면 먼저 `xcode-select --install`
- macOS 14 이상

## 처음 켤 때

1. **화면 및 시스템 오디오 녹음 권한**을 물어보면 허용 → 시스템 설정에서 Undertone 켜기
2. 메뉴 막대 파형 아이콘 → **오디오 다시 연결**
3. 음악 틀면 배경이 반응함

> 재빌드하면 권한이 풀릴 수 있어. 그럴 땐 시스템 설정에서 Undertone을 껐다 켜거나, 목록에서 지우고 다시 허용.

## 메뉴 (메뉴 막대 파형 아이콘)

| 항목 | 설명 |
|---|---|
| 전체화면으로 보기 | Undertone을 전체화면 Space로 띄움. Esc로 나가면 다시 바탕화면 모드 |
| 시작할 때 전체화면 | 켜질 때 바로 전체화면 |
| 3D 막대 / 소리의 천 / 물결 선 / 컷아웃 / 궤도 / 색면 / 오로라 / 펄스 / 내 이미지 | 배경 스타일 |
| 배경 이미지 선택… | 내 사진을 배경으로, 음악에 맞춰 숨쉬듯 움직임 |
| 반응 강도 | 슬라이더 0.2x ~ 3.0x (박자 움직임 크기에도 적용) |
| 같이 켤 앱 | 기본값 Verci, Lumn. 이름이 다르면 "편집…"에서 수정 |
| 로그인 시 자동 실행 | 맥 켜면 Undertone → Verci·Lumn 순서로 자동 실행 |

> 이 아이콘을 시스템 설정 → 메뉴 막대에서 끄면 메뉴를 못 열어. 켜두는 걸 추천.

## 전체화면 팁

- Spotlight에서 Undertone을 다시 열어도 전체화면으로 들어감
- 옆에 가사를 띄우려면: 전체화면 상태에서 Mission Control(F3) → Verci 창을 위쪽 Undertone Space로 드래그 → 화면 분할
- ⌃⌘F 전체화면 전환, ⌘W 닫기, ⌘Q 종료

## 구조

- `AudioReactor.swift` — ScreenCaptureKit으로 시스템 오디오 캡처 → 베이스/미드/하이 + 비트 검출
- `WallpaperView.swift` — 배경 스타일 (SwiftUI Canvas)
- `BarField.swift` — 3D 막대 (SceneKit, 정사각 기둥 그리드, 비트 동기 움직임)
- `AppDelegate.swift` — 바탕화면 레벨 창(모니터마다 하나), 메뉴
- `Companions.swift` — 같이 켤 앱 찾기·실행
- `ColorSync.swift` — 색 결정: Lumn 고정색 → 앨범 커버 색 → 기본 파랑
- `NowPlaying.swift` / `Palette.swift` / `LumnLink.swift` — 예전 Undertone에서 가져온 앨범 색 추출·Lumn 설정 읽기
- `ArtLayers.swift` — 추상미술 배경 4종 (물결 선, 컷아웃, 궤도, 색면) + 박자 시계(Groove)
- 오디오는 16칸(40Hz~12kHz)으로 나눠서 모든 배경에 연결: 낮은 소리는 크고 가운데, 높은 소리는 작고 가장자리
