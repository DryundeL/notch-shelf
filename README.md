# Notch Shelf

Нативный agent для menu bar macOS на Swift 6 и AppKit. Сейчас реализован минимальный запуск: собственный значок `NS` и меню выхода. Панель, настройки и работа с дисплеями пока представлены заготовками с пояснениями.

## Структура

Папки приложения находятся непосредственно в корне. Вся документация, включая описание папок, собрана в [docs/](docs/README.md).

```text
App/                         # точка входа и координация жизненного цикла
Domain/                      # чистые модели, состояния и геометрия
Ports/                       # контракты системных адаптеров
Infrastructure/              # UserDefaults, дисплеи, системные сервисы
Presentation/                # status item, будущая панель и настройки
Resources/                   # Info.plist и будущие ресурсы приложения
NotchShelfTests/              # unit-тесты, сценариев пока нет
NotchShelfUITests/            # UI-тесты, сценариев пока нет
NotchShelf.xcodeproj/         # три таргета и общая схема NotchShelf
docs/                       # спецификация, решения, задачи и описание структуры
  adr/                       # архитектурные решения
  tasks/                     # план и критерии приёмки
  structure/                 # назначение папок и будущих компонентов
  DEPENDENCIES.md             # зависимости и инструменты
README.md
.gitignore
```

## Документация

- [Навигация по документации](docs/README.md)
- [Требования](docs/01-product-requirements.md)
- [Архитектура](docs/03-architecture.md)
- [Зависимости](docs/DEPENDENCIES.md)
- [План работ](docs/tasks/plan.md) и [задачи](docs/tasks/todo.md)

Внешних зависимостей нет. Swift-файлы заготовок описывают будущую реализацию и соответствующую задачу; наличие файла не означает готовность функции.

## Сборка и запуск

Открыть `NotchShelf.xcodeproj`, выбрать схему `NotchShelf` и запустить через Run.
Приложение появляется в menu bar как `NS`, без окна и значка Dock. Выход — из меню значка.

Локальная сборка без Developer ID:

```bash
xcodebuild -project NotchShelf.xcodeproj -scheme NotchShelf \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

Для проверки сборки приложения и обоих тестовых таргетов заменить `build` на `build-for-testing`.
Тестовых сценариев пока нет. Результат сборки: `build/DerivedData/Build/Products/Debug/NotchShelf.app`.

Среда разработки: Xcode 27.0 (27A266a), Swift 6.4, SDK macOS 27.0, arm64.
Выбраны Swift language mode 6 и deployment target macOS 14.0; запуск на macOS 14 ещё требует проверки.
Доступны Debug, Profile и Release. Bundle identifier `local.notchshelf.app` временный.
Подпись и notarization описаны в [плане выпуска](docs/12-build-release.md).
