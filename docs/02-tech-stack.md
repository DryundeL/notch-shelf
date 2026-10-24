# Технологический стек и окружение

## Production stack
| Задача | Выбор | Аргумент |
|---|---|---|
| Язык | Swift 6 (режим Swift concurrency аккуратно и поэтапно) | native / низкий overhead |
| Основной UI | AppKit (`NSApplication`, `NSStatusItem`, `NSPanel`) | контроль окон и событий |
| Settings | SwiftUI в `NSHostingView` / `Settings` | локальный UI, lazy |
| Графика | Core Animation / CALayer | короткие анимации, off при idle |
| Дисплеи | NSScreen + CoreGraphics display callback | события конфигурации |
| Accessibility | ApplicationServices AX APIs | только capability-gated |
| Автозапуск | ServiceManagement / `SMAppService.mainApp` | login item macOS |
| Настройки | UserDefaults + Codable | без БД |
| Логи | OSLog / Logger | без файлового постоянного дампа |
| Тесты | XCTest, XCUITest, Instruments | системная валидация |
| Packaging | Xcode archive, Developer ID, notarytool | вне Mac App Store |
| Обновления | отсутствуют в MVP, Sparkle после аудита | меньше attack surface |

## Чего нет
Electron, Node runtime, сервер, SQLite, polling timer на 10–100 мс, постоянный ScreenCaptureKit stream, XPC-helper без обоснования.

## Развёртывание окружения
1. Установить полноценный Xcode из App Store/Apple Developer.
2. В Xcode: принять лицензию, установить компоненты по запросу.
3. Выполнить:
```bash
sw_vers
uname -m
xcodebuild -version
swift --version
xcrun --sdk macosx --show-sdk-version
```
4. Создать macOS App project: Swift, AppKit lifecycle (или вручную `@main` AppDelegate), deployment target после PoC.
5. В `Info.plist`: `LSUIElement = YES` для agent app.
6. Разнести таргеты `NotchShelf`, `NotchShelfTests`, `NotchShelfUITests`.
7. Для подписи релизов потребуется Apple Developer Program; локальную разработку можно начать без платной подписки.

## Xcode настройки
- Предупреждения компилятора максимально строгие.
- Hardened Runtime для Developer ID distribution (проверить entitlements).
- Санитайзеры для debug/test по возможности; debug memory graph.
- Build configurations: Debug, Profile, Release.
- Lock dependency versions, проверять их лицензии и supply chain.

## Минимум внешних зависимостей
Предпочесть ноль. Если использовать Sparkle, добавлять только в отдельной release-фазе с проверкой подписи обновлений и каналов.
