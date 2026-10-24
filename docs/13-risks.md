# Реестр рисков

| ID | Риск | Severity | Митигирование |
|---|---|---|---|
| R01 | Нет публичного API для перемещения чужих items | critical | PoC-first, capability backend, native reveal fallback |
| R02 | Private API ломается на macOS update | critical | OS build allowlist, disabled-by-default, test matrix |
| R03 | Скрытые items недоступны при падении | critical | native recovery, safe mode, persisted restore intent |
| R04 | Подделка «клика» запускает не то меню | high | no blind click, validate item + position, fallback |
| R05 | AX доступ слишком широк | high | permission gating, no personal content retention |
| R06 | Screen Recording захватывает частные данные | high | avoid unless necessary; no persistent captures |
| R07 | Memory leak в NSPanel/observer/image cache | high | Instruments, reuse, teardown, cost limited cache |
| R08 | Multi-monitor coordinates неверны | high | points/pixels conversion, geometry unit tests |
| R09 | Нет стабильного item ID | high | heuristic identity, no destructive auto move |
| R10 | Reconciliation spin on events | medium | debounce, bounded retries, event coalescing |
| R11 | Другая утилита управляет status bar | medium | conflict warning, suspend automation |
| R12 | GPL contamination при копировании Ice | high | license review; архитектурное изучение без копирования |
| R13 | Notarization/App Store rejected | high | direct DMG, minimal permissions, private API risk register |
| R14 | Автозапуск включён без согласия | medium | explicit opt-in, SMAppService only |
| R15 | Изменения Full Screen/Spaces скрывают shelf | medium | per-mode smoke tests and fallback |

## Решение о риске
Каждая новая функция указывается в capability matrix с ОС, разрешениями, failure mode, recovery и тест-кейсами. Не выпускать экспериментальный private backend как основной без rollback.
