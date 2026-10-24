# Presentation

AppKit UI на `@MainActor`; SwiftUI допускается для ленивого окна настроек.

- `StatusItemController.swift`: собственный NSStatusItem и меню выхода уже реализованы.
- `ShelfPanelController.swift`: одна ленивая NSPanel, задача 8.
- `SettingsView.swift`: настройки и их валидация через application layer, задача 11.

UI не реализует правила, persistence и AX-обход. До реализации панели status item открывает только меню.
