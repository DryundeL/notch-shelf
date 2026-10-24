# Multi-monitor и notch positioning

## Ключевой принцип
Модель item visibility **глобальна**, UI-представление и настройки **per display**. Не предполагать, что каждый NSScreen содержит отдельный редактируемый список status items.

## Discovery
- `NSScreen.screens` — окна, `frame`, `visibleFrame`, `safeAreaInsets`, `auxiliaryTopLeftArea`, `auxiliaryTopRightArea` по доступности.
- CoreGraphics display IDs/callbacks — topology и конфигурация.
- Screen frame coordinates в points, CoreGraphics часто pixels; явное преобразование, Retina scale.
- Notch определять по действительной top safe area/auxiliary regions, **не по имени монитора**.
- `CGDirectDisplayID` не надёжен как вечный persisted identity. Сопоставление по набору характеристик с conflict handling и fallback.

## Выбор дисплея
1. По клику на status item — экран window/status item если надёжно определён.
2. По hover — экран текущего pointer location.
3. По hotkey — экран курсора (настройка) или active window.
4. При отключении — ближайший активный экран либо main display.

## Геометрия панели
- Notch mode: визуально привязать к центру верхней safe-area зоны; не покрывать системные controls без UX решения.
- Floating mode: anchor под menu bar, clamp внутри `visibleFrame`.
- Minimal: reveal нативной секции, отдельной панели может не быть.
- Рассчитывать размеры панели по content intrinsic sizes, max width <= width текущего экрана за margin.
- Учитывать масштабирование, rotation, расположение мониторов слева/справа/сверху.
- При слишком малом экране включать scroll для контента, не уменьшать кликабельность.

## События и Spaces
- Подписка на `NSApplication.didChangeScreenParametersNotification` и при необходимости CG display callback; coalesce повторяющиеся события.
- При sleep/wake, смене primary display, resolution, mirroring, dock/auto-hide меню перепроверять anchor.
- Full Screen / Spaces: `NSPanel.collectionBehavior` и window level протестировать; не навязывать панель везде без consent.
- Один lazily-created NSPanel, reposition; если animation running — cancel + reposition.
- Нет непрерывного отслеживания координат курсора, кроме режима hover в ограниченной области и с низкой частотой событийной обработки.

## Матрица
- Встроенный notch + HDMI external no-notch.
- Два внешних, одинаковые display names.
- Retina + non-Retina, разные DPI.
- Display mirroring vs extended.
- Один монитор отключается во время открытой шторки.
- Screen arrangement меняется после сна.
- Hide menu bar always/automatically, Full Screen, multiple Spaces.

## Обязательный инвариант
После изменения топологии все панели либо целиком видны на существующем дисплее, либо закрыты; процесс не должен удерживать выведенное за экран окно.
