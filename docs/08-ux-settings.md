# UX и настройки

## Поведение UI
- Status icon: click toggle, option-click recovery (после проверки conflicts), context menu: Settings, Reveal All, Quit.
- Shelf: compact, keyboard focus, Escape close, accessibility labels, VoiceOver.
- Notch: anchored под вырезом встроенного дисплея, с отступами и без перекрытия системных controls.
- External: floating panel под menu bar выбранного монитора; без имитации notch по умолчанию.
- Если «клик по чужому item» недоступен, UI предлагает reveal native section, а не вводит пользователя в заблуждение.
- Hover: configurable sensitivity zone / dwell delay; гистерезис при выходе, иначе flicker.
- Animations: off полностью; Reduce Motion уважать и применять автоматически по выбору пользователя.

## Settings schema
```json
{
  "schemaVersion": 1,
  "launchAtLogin": false,
  "autoHideNewItems": false,
  "showOnHover": false,
  "hoverDwellMs": 250,
  "dismissDelayMs": 700,
  "animationsEnabled": true,
  "animationDurationMs": 160,
  "hotkey": null,
  "fallbackMode": "revealNativeSection",
  "defaultDisplayMode": "floating",
  "perDisplayProfiles": {},
  "pinnedBundleIDs": [],
  "excludedBundleIDs": []
}
```
При миграции version bump с валидацией диапазонов; неизвестные значения -> безопасные defaults. Persisted IDs items нельзя считать гарантированно стабильными.

## Секции Settings
1. General: login, launch behavior, permissions, safe mode.
2. Appearance: notch / floating / minimal, dimensions, animation, reduce motion.
3. Interactions: click, hover, hotkey, auto-hide delays.
4. Rules: pinned, excluded, new items, reset rules.
5. Displays: текущие экраны, индивидуальные профили, preview.
6. Diagnostics: capability report, OS version, export redacted debug, reveal all.

## Accessibility UX
Все действия доступны с клавиатуры. Отдельные labels на icons; контраст системных цветов; dynamic type где применимо. Не скрывать системную строку меню целиком. Поддерживать dark/light режим.
