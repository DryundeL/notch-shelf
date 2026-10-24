# Зависимости и инструменты

Внешних зависимостей нет: установка пакетов, CocoaPods, Carthage, SPM-пакеты и lock-файлы не нужны.
Проект собирается напрямую Xcode; генератор проекта не требуется.

Сейчас используются Swift 6 и системный AppKit (NSApplication, NSStatusItem, NSMenu).
По плану подключаются системные Foundation (модели, UserDefaults, Codable), SwiftUI (настройки),
CoreGraphics (дисплеи), QuartzCore (анимации), ServiceManagement (автозапуск), OSLog (безопасные логи).
ApplicationServices/AX допускается только после go/no-go задачи 5 и явного включения функции.
XCTest/XCUITest поставляются с Xcode; Instruments нужен для ручного профилирования.

Baseline сборки — macOS 14.0, Swift language mode 6, конфигурации Debug/Profile/Release.
Сборка с deployment target 14.0 сама по себе не подтверждает запуск на macOS 14: нужен отдельный Mac/VM.

Для локальной проверки использовать CODE_SIGNING_ALLOWED=NO. Распространение требует отдельной
настройки Developer ID и notarization (задача 24). Entitlements не добавлены;
решение о Sandbox остаётся открытым в соответствии с планом.
Sparkle, сеть, сервер, БД и privileged helper в каркас не входят.
