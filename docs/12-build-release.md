# Build, deployment и обновления

## Debug
```bash
xcodebuild -list -project NotchShelf.xcodeproj
xcodebuild -project NotchShelf.xcodeproj \
  -scheme NotchShelf -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```
Проект и общая схема уже созданы. `CODE_SIGNING_ALLOWED=NO` предназначен для локальной проверки сборки; релиз требует подписи. Сборка тестовых таргетов: та же команда с `build-for-testing` вместо `build`. Тестовых сценариев пока нет.

## App configuration
- LSUIElement: true.
- Bundle identifier: собственный reverse-DNS.
- Entitlements только после выяснения требований.
- No root helpers / privileged launch daemon.
- Privacy usage descriptions только для реально используемых возможностей, с проверкой TCC UX.
- Не включать App Sandbox/отключать его автоматически без анализа: проверить совместимость с требуемыми системными API и выбранным каналом распространения.

## Release pipeline
1. Build/test Release с pinned Xcode/macOS SDK.
2. Archive `.app`.
3. Codesign с **Developer ID Application**.
4. Verify signature and Hardened Runtime.
5. Package ZIP/DMG.
6. `xcrun notarytool submit ... --wait` с конфигурацией учётных данных.
7. Staple ticket к поддерживаемому пакету/приложению и проверить `spctl`.
8. Smoke test на чистом Mac без прежних TCC разрешений.

Пример диагностических команд:
```bash
codesign --verify --deep --strict --verbose=2 /path/to/NotchShelf.app
spctl --assess --type execute --verbose /path/to/NotchShelf.app
xcrun notarytool --help
```
Полную автоматизацию формировать только после получения Apple Developer credentials и структуры проекта; секреты — CI secrets/Keychain, никогда Git.

## Updates
MVP: ручной выпуск подписанных релизов. Позже: Sparkle с проверкой подписи, защищённым update feed, staged rollout, rollback.

## Compatibility
На старте оценить OS build и доступные backend capabilities. Если нестандартный backend не сертифицирован для данной версии — disable и safe native fallback. Не интерпретировать «успешная сборка» как доказательство работоспособности menu bar.
