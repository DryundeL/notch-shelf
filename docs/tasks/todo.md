# Задачи: Notch Shelf

План и скелет: [plan.md](plan.md). Каркас и команды сборки уже добавлены в [корневой README](../../README.md). AppMain и status item реализованы; остальные файлы — заготовки с комментариями. Наличие каркаса не закрывает задачи: ручные проверки и будущая логика остаются по критериям ниже.

Definition of Done на каждую задачу, сверх критериев ниже: AppKit на main actor, никаких новых TCC-запросов без явного действия, ошибка не оставляет значки без способа вернуть.

## Phase 0: Feasibility

### Task 1: Agent shell

**Description:** macOS-приложение Swift/AppKit: `LSUIElement`, один свой `NSStatusItem` с пунктом Quit, два test target. Без панели, таймеров, сети и запросов разрешений.

**Acceptance criteria:**
- [ ] В Dock иконки нет, status item есть, Quit завершает процесс (`ps` его не показывает).
- [ ] Первый запуск не показывает диалоги Accessibility, Screen Recording, Input Monitoring.
- [ ] Зависимостей в проекте нет.

**Verification:**
- [ ] Build: `xcodebuild -project NotchShelf.xcodeproj -scheme NotchShelf -configuration Debug build`
- [ ] Tests: таргет собирается, тестов ещё нет — это нормально
- [ ] Manual: запуск собранного `.app`, Quit, проверка диалогов разрешений

**Dependencies:** None

**Files likely touched:**
- `NotchShelf.xcodeproj`
- `App/AppMain.swift`
- `Presentation/StatusItemController.swift`
- `Resources/Info.plist`
- `NotchShelfTests/`, `NotchShelfUITests/`

**Estimated scope:** Medium

### Task 2: Разделители секций

**Description:** Два собственных status item как границы секции. Записать, остаются ли между ними тестовые значки после перезапуска и можно ли сдвинуть их Command-drag там, где ОС это позволяет. Эксперимент не объявлять функцией продукта.

**Acceptance criteria:**
- [ ] В `docs/capability-matrix.md` есть строка: OS build, дисплей, результат `works` / `partial` / `no`.
- [ ] Код эксперимента либо удалён, либо не прячет ничего на обычном запуске.

**Verification:**
- [ ] Build: схема `NotchShelf` собирается
- [ ] Manual: перезапуск приложения и повторный взгляд на menu bar

**Dependencies:** Task 1

**Files likely touched:**
- `Presentation/StatusItemController.swift`
- `docs/capability-matrix.md`

**Estimated scope:** Medium

### Task 3: Обзор AX, без кода в приложении

**Description:** На 6–10 чужих menu bar приложениях вручную проверить, стабильны ли идентификация item и открытие настоящего меню. Заголовки окон и снимки экрана не сохранять. Private API не использовать.

**Acceptance criteria:**
- [ ] В `docs/capability-matrix.md` строки: приложение, identify, реальное меню, смена иконки/badge, failure mode.
- [ ] В репозитории приложения нет AX-вызовов.

**Verification:**
- [ ] Manual: матрица заполнена, Accessibility после обзора можно отозвать
- [ ] Build не требуется: исходники приложения не меняются

**Dependencies:** Task 1

**Files likely touched:**
- `docs/capability-matrix.md`

**Estimated scope:** Medium

### Task 4: Gate 1, замер idle

**Description:** Release или Profile сборка задачи 1, без отладчика. 60 с стабилизации и 5 мин idle. Записать медиану и p95 CPU, `phys_footprint`, wakeups. Ничего не оптимизировать в этой задаче.

**Acceptance criteria:**
- [ ] `docs/PERF.md` содержит числа, OS build, железо, конфигурацию сборки.
- [ ] Если порог из `07-performance.md` пробит, записан симптом trace, а не патч.

**Verification:**
- [ ] Manual: протокол из `07-performance.md`, секция Benchmark, шаги 1–2
- [ ] Сборка Profile/Release той же схемы, что в задаче 1

**Dependencies:** Task 1

**Files likely touched:**
- `docs/PERF.md`

**Estimated scope:** Small

### Task 5: Go / no-go

**Description:** По задачам 2–4 зафиксировать объём MVP. Если перенос или активация чужих items неустойчивы, задачи 17–20 отменяются. Остаётся своя шторка и reveal нативной секции, без имитации клика.

**Acceptance criteria:**
- [ ] В `docs/capability-matrix.md` есть решение `conceal in scope` или `cancelled`, с датой и OS build.
- [ ] Человек подтвердил решение до старта фазы 4.

**Verification:**
- [ ] Manual: решение записано, отменённые задачи в этом файле помечены

**Dependencies:** Tasks 2, 3, 4

**Files likely touched:**
- `docs/capability-matrix.md`
- `tasks/todo.md`

**Estimated scope:** Small

## Checkpoint: после задач 1–5

- [ ] Agent собирается и завершается по Quit
- [ ] `docs/PERF.md` и capability matrix существуют
- [ ] Решение по conceal подтверждено человеком
- [ ] Дальше не идём в задачи 17–20 без `conceal in scope`

## Phase 1: Панель

### Task 6: Автомат панели

**Description:** Чистая машина состояний `closed / opening / open / closing`. Повторный клик идемпотентен. Смена экрана отменяет переход. Без AppKit.

**Acceptance criteria:**
- [ ] Тест быстрого повторного клика не копит состояния.
- [ ] Тест отмены на середине открытия возвращает `closed` без хвоста анимации.

**Verification:**
- [ ] Tests: `xcodebuild -project NotchShelf.xcodeproj -scheme NotchShelf -destination 'platform=macOS' test -only-testing:NotchShelfTests/ShelfStateTests`
- [ ] Build: схема `NotchShelf`

**Dependencies:** Task 1

**Files likely touched:**
- `Domain/ShelfState.swift`
- `NotchShelfTests/ShelfStateTests.swift`

**Estimated scope:** Small

### Task 7: Геометрия якоря

**Description:** Расчёт anchor и clamp по фикстурам `DisplaySnapshot`: отрицательный origin, смешанный scale, узкий экран, notch против floating. Notch не выводится из имени монитора — во фикстуре это уже посчитанный флаг.

**Acceptance criteria:**
- [ ] Панель целиком внутри `visibleFrame`, включая экран с отрицательным origin.
- [ ] Ширина не больше экрана минус поле; при нехватке высоты тесты фиксируют режим scroll, а не уменьшение hit target.

**Verification:**
- [ ] Tests: `-only-testing:NotchShelfTests/GeometryTests`

**Dependencies:** Task 1

**Files likely touched:**
- `Domain/Geometry.swift`
- `Domain/DisplaySnapshot.swift`
- `NotchShelfTests/GeometryTests.swift`

**Estimated scope:** Medium

### Task 8: Одна ленивая панель

**Description:** Клик по status item открывает одну `NSPanel`, Escape и клик снаружи закрывают. Повторный клик не создаёт второе окно. Анимации в этой задаче нет: показать и скрыть сразу. Панель не создаётся при старте.

**Acceptance criteria:**
- [ ] После старта `NSPanel` нет, пока не было клика.
- [ ] Второй клик в `open` закрывает, а не создаёт ещё одну панель.
- [ ] Escape закрывает. Клик снаружи закрывает.

**Verification:**
- [ ] Build: Debug scheme `NotchShelf`
- [ ] Tests: `ShelfStateTests` всё ещё зелёные
- [ ] Manual: клик, повторный клик, Escape, клик снаружи

**Dependencies:** Tasks 6, 7

**Files likely touched:**
- `Presentation/ShelfPanelController.swift`
- `Presentation/StatusItemController.swift`
- `Domain/ShelfState.swift`

**Estimated scope:** Medium

### Task 9: Notch и floating на живом экране

**Description:** `hasNotch` из top safe area / auxiliary region, не из модели Mac. Встроенный экран с вырезом — notch anchor. Внешний — floating под menu bar. Окно за край `visibleFrame` не выходит.

**Acceptance criteria:**
- [ ] На внешнем экране нет нарисованной чёлки.
- [ ] Панель целиком на том дисплее, с которого пришёл клик.
- [ ] В `docs/PERF.md` одна строка Gate 3: footprint до создания панели и после, без правок «заодно».

**Verification:**
- [ ] Tests: `GeometryTests`
- [ ] Manual: встроенный экран и один внешний, если он подключён. Нет внешнего — записать пропуск, не симулировать notch

**Dependencies:** Task 8

**Files likely touched:**
- `Presentation/ShelfPanelController.swift`
- `Domain/Geometry.swift`
- `docs/PERF.md`

**Estimated scope:** Medium

## Checkpoint: после задач 6–9

- [ ] Клик открывает одну панель на экране клика и закрывает её
- [ ] Unit-тесты состояния и геометрии проходят
- [ ] Gate 3 записан, оптимизаций поверх него нет

## Phase 2: Настройки и восстановление

### Task 10: Schema настроек v1

**Description:** `UserDefaults` + `Codable`, `schemaVersion`. Хранить только то, что уже читает продукт: `launchAtLogin` (значение, регистрация в задаче 21), `animationsEnabled`, `animationDurationMs`, `dismissDelayMs`, `fallbackMode`, режим дисплея. Битые данные и неизвестные значения заменяются безопасными defaults. Автоскрытие выключено и в схеме его нет.

**Acceptance criteria:**
- [ ] Повреждённый payload не включает скрытие и не роняет запуск.
- [ ] Неизвестные ключи не меняют defaults.
- [ ] Диапазоны длительностей ограничены (ноль и абсурдно большие не проходят).

**Verification:**
- [ ] Tests: `-only-testing:NotchShelfTests/SettingsMigrationTests`

**Dependencies:** Task 1

**Files likely touched:**
- `Ports/SettingsStore.swift`
- `Infrastructure/UserDefaultsSettingsStore.swift`
- `NotchShelfTests/SettingsMigrationTests.swift`

**Estimated scope:** Medium

### Task 11: Окно настроек по требованию

**Description:** SwiftUI внутри `NSHostingView`, пункт меню Settings. Окно создаётся при открытии, не при старте. Секции: General (тумблер логина без регистрации до задачи 21) и Appearance (анимации).

**Acceptance criteria:**
- [ ] До выбора Settings hosting view не создан.
- [ ] Тумблер анимации пишется в store и читается обратно.
- [ ] Окно не запрашивает TCC.

**Verification:**
- [ ] Build: Debug scheme
- [ ] Tests: `SettingsMigrationTests`
- [ ] Manual: открыть Settings, переключить анимацию, перезапустить, значение на месте

**Dependencies:** Task 10

**Files likely touched:**
- `Presentation/SettingsView.swift`
- `Presentation/StatusItemController.swift`
- `Infrastructure/UserDefaultsSettingsStore.swift`

**Estimated scope:** Medium

### Task 12: Анимация и Reduce Motion

**Description:** Панель анимируется только если анимация включена и системный Reduce Motion выключен. Иначе переход мгновенный. Длительность из настроек. Display link не заводится.

**Acceptance criteria:**
- [ ] Reduce Motion гасит анимацию даже при включённом тумблере.
- [ ] В idle после закрытия нет незавершённой анимации и display link.

**Verification:**
- [ ] Manual: четыре комбинации тумблера и Reduce Motion
- [ ] Tests: `ShelfStateTests` (отмена перехода не зависит от анимации)

**Dependencies:** Tasks 8, 10

**Files likely touched:**
- `Presentation/ShelfPanelController.swift`
- `Presentation/SettingsView.swift`

**Estimated scope:** Small

### Task 13: Reveal All до любого скрытия

**Description:** Пункты меню Reveal All и безопасный режим. На диске маркер «нужно восстановить доступ». При старте с маркером приложение не выполняет conceal (conceal ещё и нет). Кнопка работает без private backend и без Accessibility.

**Acceptance criteria:**
- [ ] Reveal All доступен с первого запуска и ничего не прячет.
- [ ] Маркер, выставленный вручную в тесте, на старте приводит к видимому menu bar и снимается только после успешного прохода.
- [ ] Quit снимает observers панели и status item.

**Verification:**
- [ ] Tests: старт с маркером в `NotchShelfTests` на store/маркере, без UI
- [ ] Manual: Reveal All при открытой и закрытой панели
- [ ] Build: Debug scheme

**Dependencies:** Tasks 1, 10

**Files likely touched:**
- `App/AppCoordinator.swift`
- `Presentation/StatusItemController.swift`
- `NotchShelfTests/RecoveryMarkerTests.swift`

**Estimated scope:** Medium

## Checkpoint: после задач 10–13

- [ ] Настройки переживают перезапуск, битый store не включает скрытие
- [ ] Reveal All есть до появления backend скрытия
- [ ] Settings не создаются при обычном старте

## Phase 3: Дисплеи

### Task 14: Снимок дисплеев и выбор цели

**Description:** Immutable snapshot из `NSScreen`: frame, visibleFrame, scale, флаг notch. Выбор экрана: экран status item, иначе экран курсора в момент клика или хоткея, иначе main. Подписка на `didChangeScreenParametersNotification` с coalesce. Непрерывного опроса курсора нет. `CGDirectDisplayID` не используется как вечный ключ.

**Acceptance criteria:**
- [ ] Серия одинаковых notification даёт один пересчёт.
- [ ] Клик выбирает экран status item, когда он известен.
- [ ] В idle нет таймера геометрии.

**Verification:**
- [ ] Tests: coalesce и выбор цели на фейковом `DisplayProvider`
- [ ] Manual: клик на встроенном и внешнем экране

**Dependencies:** Tasks 7, 9

**Files likely touched:**
- `Ports/DisplayProvider.swift`
- `Infrastructure/ScreenDisplayProvider.swift`
- `Domain/DisplaySnapshot.swift`
- `NotchShelfTests/DisplayPolicyTests.swift`

**Estimated scope:** Medium

### Task 15: Отключение монитора при открытой панели

**Description:** Пока панель открыта, отключение экрана переносит её на оставшийся или закрывает. Окно за пределами всех `visibleFrame` не остаётся. Sleep/wake и смена primary перепроверяют anchor. Анимация, если шла, отменяется.

**Acceptance criteria:**
- [ ] После потери экрана панель либо целиком на живом дисплее, либо `closed`.
- [ ] Повторные callback не ставят вторую панель.

**Verification:**
- [ ] Tests: политика на последовательности snapshot (экран исчез)
- [ ] Manual: выдернуть внешний монитор при открытой панели. Нет второго монитора — тест политики обязателен, ручной шаг помечен пропуском

**Dependencies:** Tasks 8, 14

**Files likely touched:**
- `Infrastructure/ScreenDisplayProvider.swift`
- `Presentation/ShelfPanelController.swift`
- `NotchShelfTests/DisplayPolicyTests.swift`

**Estimated scope:** Medium

### Task 16: Режим на дисплей

**Description:** Best-effort ключ профиля дисплея и режим `notch` / `floating` / `minimal`. `minimal` не создаёт панель: остаётся status item и Reveal All. Конфликт двух дисплеев с одинаковым именем не затирает чужой профиль молча — fallback на `floating`.

**Acceptance criteria:**
- [ ] Внешний дисплей по умолчанию `floating`, не `notch`.
- [ ] `minimal` не оставляет скрытую панель.
- [ ] Два экрана с одним именем не делят один профиль без разведения конфликта.

**Verification:**
- [ ] Tests: ключ профиля и fallback конфликта
- [ ] Manual: смена режима в Settings для текущего экрана

**Dependencies:** Tasks 10, 14

**Files likely touched:**
- `Infrastructure/UserDefaultsSettingsStore.swift`
- `Presentation/SettingsView.swift`
- `Domain/DisplaySnapshot.swift`
- `NotchShelfTests/SettingsMigrationTests.swift`

**Estimated scope:** Medium

## Checkpoint: после задач 14–16

- [ ] Панель не остаётся за выключенным монитором
- [ ] Режим minimal не рисует шторку
- [ ] Политика дисплеев покрыта тестами без железа

## Phase 4: Conceal, только если задача 5 = in scope

Если задача 5 = `cancelled`, задачи 17–20 не делаются. Переход к фазе 5.

### Task 17: Backend секции

**Description:** Протокол из `09-domain-and-interfaces.md` и один адаптер на то, что разрешила задача 5. Результат операции: supported / unsupported / permissionDenied / transientFailure / conflict. Actor сериализует вызовы. Повторы ограничены, шторма нет. Неизвестный OS-путь не двигает items.

**Acceptance criteria:**
- [ ] Неподдерживаемая операция возвращает typed error и не меняет menu bar.
- [ ] Два параллельных вызова не исполняются одновременно.
- [ ] Адаптер не использует private API.

**Verification:**
- [ ] Tests: фейковый backend на каждый тип ошибки и на сериализацию
- [ ] Manual: одна операция reveal/conceal на этом Mac, результат дописан в capability matrix

**Dependencies:** Tasks 5, 13

**Files likely touched:**
- `Ports/MenuBarBackend.swift`
- `Infrastructure/SectionBackend.swift`
- `NotchShelfTests/MenuBarBackendTests.swift`

**Estimated scope:** Medium

### Task 18: Conceal только opt-in и откат

**Description:** Скрытие секции включается явным действием. Перед ним пишется маркер восстановления. Неудача или kill на следующем старте вызывает restore. Reveal All вызывает `restoreUserAccess` публичного пути и работает, даже если адаптер вернул unsupported.

**Acceptance criteria:**
- [ ] До явного согласия секция не скрывается.
- [ ] Сбой backend оставляет items доступными или возвращает их на следующем старте.
- [ ] Reveal All не требует Accessibility.

**Verification:**
- [ ] Tests: маркер + ошибка backend → restore
- [ ] Manual: `kill -9` в скрытом состоянии, следующий запуск возвращает доступ. Шаг обязателен до любого релиза с conceal

**Dependencies:** Tasks 13, 17

**Files likely touched:**
- `App/AppCoordinator.swift`
- `Infrastructure/SectionBackend.swift`
- `NotchShelfTests/RecoveryMarkerTests.swift`

**Estimated scope:** Medium

### Task 19: Правила без автоскрытия

**Description:** Чистая функция: известные items, правила `pinVisible` / `preferHidden` / `ask`, capabilities. Неизвестный item даёт `ask` и ноль действий backend. `preferHidden` не исполняется, если capability conceal нет.

**Acceptance criteria:**
- [ ] Неизвестный item не порождает conceal.
- [ ] `pinVisible` побеждает `preferHidden` для того же bundle.
- [ ] Дубликаты и исчезнувшие id не дают повторного conceal.

**Verification:**
- [ ] Tests: `-only-testing:NotchShelfTests/RulesEngineTests`

**Dependencies:** Task 18

**Files likely touched:**
- `Domain/RulesEngine.swift`
- `Domain/MenuItem.swift`
- `NotchShelfTests/RulesEngineTests.swift`

**Estimated scope:** Medium

### Task 20: Запрос Accessibility по действию

**Description:** Только если задача 5 оставила функцию, которой нужен AX. Объяснение в UI, запрос в момент включения, не при старте. Отзыв права выключает функцию и не крутит retry.

**Acceptance criteria:**
- [ ] Холодный запуск с выключенной функцией не вызывает системный prompt.
- [ ] После отзыва в System Settings UI показывает недоступность и остаётся отзывчивым.
- [ ] Screen Recording не запрашивается.

**Verification:**
- [ ] Manual: чистый TCC (или новый пользователь macOS), старт, затем включение функции, затем отзыв
- [ ] Tests: политика «функция выключена → backend не зовётся»

**Dependencies:** Tasks 5, 17

**Files likely touched:**
- `App/AppCoordinator.swift`
- `Presentation/SettingsView.swift`
- `Infrastructure/SectionBackend.swift`

**Estimated scope:** Medium

## Checkpoint: после задач 17–20

- [ ] Пропустить целиком, если conceal отменён
- [ ] Иначе: скрытие opt-in, `kill -9` не оставляет items недоступными
- [ ] AX prompt отсутствует на первом запуске

## Phase 5: Вход в систему и выпуск

### Task 21: Автозапуск по согласию

**Description:** `SMAppService.mainApp`. По умолчанию выключено. Тумблер в Settings регистрирует и снимает login item. Ошибка API показывается текстом, без повтора в цикле.

**Acceptance criteria:**
- [ ] Свежая установка не регистрирует login item.
- [ ] Выключение тумблера снимает регистрацию.
- [ ] Состояние тумблера совпадает со статусом `SMAppService` после перезапуска.

**Verification:**
- [ ] Manual: включить, выйти из сессии или проверить статус сервиса, выключить
- [ ] Tests: store хранит флаг; вызов API за интерфейсом, в unit-тесте подмена

**Dependencies:** Task 11

**Files likely touched:**
- `Infrastructure/LoginItemService.swift`
- `Presentation/SettingsView.swift`
- `NotchShelfTests/SettingsMigrationTests.swift`

**Estimated scope:** Small

### Task 22: Прогон бюджета

**Description:** Протокол `07-performance.md`: idle, 100 циклов панели, смена топологии если есть второй монитор, анимации on/off, Accessibility denied/granted если фаза 4 есть. Один эксперимент за раз. Улучшение внутри шума прогона откатывается. Журнал в `docs/PERF.md`.

**Acceptance criteria:**
- [ ] Таблица попыток: идея, baseline, результат, kept или reverted.
- [ ] Частый wakeup в idle или монотонный рост footprint после 100 циклов не остаётся в сборке.
- [ ] Новых кэшей, таймеров и display link нет, если замер их не потребовал и повторный замер не подтвердил.

**Verification:**
- [ ] Manual: Instruments Time Profiler и Allocations по протоколу
- [ ] Tests: существующие scheme tests зелёные на той же сборке, которую мерили

**Dependencies:** Tasks 15, 12, 21. Task 18, если она не отменена

**Files likely touched:**
- `docs/PERF.md`
- исходник только той правки, которую замер оправдал

**Estimated scope:** Medium

### Task 23: Отказы

**Description:** Пройти пункты fault injection из `10-testing.md`, которые относятся к сделанному объёму: битые настройки, отзыв AX если он подключался, `kill -9`, давление на память не устраивать ради кэша, которого нет. Результат — короткий протокол в `docs/PERF.md` или рядом с capability matrix, без нового фреймворка.

**Acceptance criteria:**
- [ ] Битые настройки → defaults, menu bar не спрятан.
- [ ] `kill -9` → следующий запуск с доступными значками.
- [ ] Нет цикла повторов при отказе разрешения.

**Verification:**
- [ ] Manual: чеклист выше на Debug-сборке
- [ ] Tests: migration и recovery уже из задач 10 и 13

**Dependencies:** Tasks 13, 15

**Files likely touched:**
- `docs/capability-matrix.md`

**Estimated scope:** Small

### Task 24: Подпись релиза

**Description:** Пустые лишние entitlements, Hardened Runtime, Developer ID, notarization, `spctl`. Без Sparkle и без `get-task-allow` в Release. Sandbox не переключать, пока не записано отдельное решение: нужен ли он для выбранных API. Секретов в git нет.

**Acceptance criteria:**
- [ ] `codesign --verify --deep --strict` и `spctl --assess` проходят на архиве.
- [ ] В Release нет сети, нет лишних usage strings, нет private API.
- [ ] Дымовой запуск на машине без старых TCC-разрешений не показывает лишний prompt.

**Verification:**
- [ ] Manual: команды из `12-build-release.md`
- [ ] Задача блокируется, пока нет учётки Apple Developer. Локальная разработка без неё закончена на задаче 23

**Dependencies:** Tasks 22, 23

**Files likely touched:**
- entitlements и настройки Release в `NotchShelf.xcodeproj`
- `Resources/Info.plist`

**Estimated scope:** Medium

## Checkpoint: готово к ручному выпуску

- [ ] P0 из `01-product-requirements.md` отмечены по фактически сделанному объёму
- [ ] Conceal либо отменён явно, либо проходит recovery
- [ ] `docs/PERF.md` объясняет, что оставили и что откатили
- [ ] Задача 24 либо сделана, либо честно ждёт Apple Developer
