# RAM / CPU / power budget и методика измерения

## Budget: целевые метрики, не обещания
| Режим | Метрика | Target (предварительно) |
|---|---|---|
| Idle, шторка закрыта | CPU после стабилизации | медиана ~0%; p95 < 1% одного логического ядра |
| Idle | phys_footprint / RAM | ориентир 15–30 MiB, проверить feasibility |
| Idle | timer wakeups | отсутствие частого polling, измерять Instruments |
| Шторка открыта с ~20 items | память | не более +15 MiB к сопоставимому idle |
| После 100 циклов открытия | память | без монотонного удерживаемого роста |
| Hot plug | время перестроения UI | ориентир до 500 мс, уточнить тестами |
| Hover -> visible | latency | ориентир <=150 мс без анимации |
| App quit | CPU/background | процесс полностью прекращён |

Все числа — **проектные пороги для обсуждения**, не результаты измерений и не SLA. SwiftUI, кэш изображений, AX snapshot и OS version могут изменить footprint. Первым измерять `phys_footprint`, RSS — вспомогательно.

## Rules
1. Событийные callbacks вместо таймеров на 50/100 мс.
2. Coalesce notifications, делать reconciliation только при изменениях.
3. Единственный `NSPanel` и settings UI lazy init.
4. NSCache costLimit и countLimit; при memory pressure invalidation.
5. Не хранить CGImage/Screenshot полноэкранного размера в памяти.
6. Не использовать continuous screen/video capture.
7. В idle — ни display link, ни бесконечных animations.
8. Observer/event monitors remove on teardown, weak callbacks.
9. AX scanning rate-limited, capped per pass и не на горячем UI path.
10. Не делать `Task.detached` storms или unbounded event queues.
11. Background diagnostics — opt-in, выключены в Release по умолчанию.
12. Дебаунс geometry recalculation на массовые callbacks.

## Профилирование
- Instruments: Allocations, Leaks, Time Profiler, Energy Log, System Trace (по необходимости).
- `xcrun xctrace list templates` для доступных шаблонов.
- `ps -o pid,rss,%cpu,command -p "$PID"` — RSS KiB.
- `footprint "$PID"` — проверять доступность утилиты на целевом macOS.
- Activity Monitor только как cross-check; не единственный источник.

## Benchmark protocol
1. Release build (или Profile) без debugger, фиксированная OS/build/hardware.
2. Baseline после 60 сек стабилизации, потом 5 минут idle.
3. 20 items, открыть/закрыть 100 раз; snap до/после; исключить эффекты кэша.
4. Hover enabled vs disabled, animations enabled vs disabled.
5. 1/2/3 монитора, Retina/non-Retina, Sleep/Wake x10.
6. Accessibility denied, revoked, granted; abnormal backend failures.
7. Зафиксировать median/p95 CPU, footprint baseline/peak, wakeups/sec, launch time.
8. При утечках — сначала retain cycle NSPanel/notifications/CGImage.

## Performance gates
- Gate 1: overhead собственного status item.
- Gate 2: добавление backend и AX discovery.
- Gate 3: создание NSPanel.
- Gate 4: snapshots/icons.
- Gate 5: multi-display interactions.
Релиз невозможен при частом wakeup в idle или воспроизводимом росте retained memory.
