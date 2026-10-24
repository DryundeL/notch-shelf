# Безопасность, конфиденциальность и системные разрешения

## Threat model
**Активы:** пользовательские настройки, доверие к приложению, наличие контроля над status items, приватное содержание изображений desktop/menu bar, code signing/update chain.

**Угрозы:** компрометация update, внедрение зависимостей, ненужный Screen Recording, утечка PII в логах, spoofing UI/кликов, застревание скрытых items, Accessibility abuse, private API incompatibility.

## Принцип минимальных привилегий
| Доступ | Когда | Правило |
|---|---|---|
| Accessibility (TCC) | для конкретной функции управления/обнаружения | объяснить и просить только по действию |
| Screen Recording | **только** если точечное получение изображений действительно требует | отдельное opt-in; нет continuous recording |
| Input Monitoring | не запрашивать по умолчанию | использовать локальный tracking и стандартные hotkeys где возможно |
| Network | отсутствует в MVP | отложить обновления/диагностику |
| Files | только собственные настройки | не читать пользовательские документы |
| Root / SIP | никогда | не запрашивать admin password |

Проверять AX trust через системный API; **не** пытаться обходить TCC. В пользовательских текстах объяснять, что Accessibility обеспечивает воздействие на UI других программ.

## Data minimization
- Хранить bundle IDs, user-defined rules и UI preferences, не названия открытых документов/окон и не их содержимое.
- Не сохранять сырые screenshot/CGImage на диск. NSCache для изображений ограничен и очищается при memory pressure.
- Диагностический лог: category, state transitions, error code, хэш/редактированный id вместо sensitive window titles.
- Не включать telemetry, analytics и crash upload по умолчанию.
- `UserDefaults` не хранит секреты; если в будущем появятся токены — Keychain.

## Integrity & release
- Подписывать Developer ID, включить Hardened Runtime, notarize.
- Минимизировать entitlements; не добавлять `get-task-allow` в релиз.
- Если используется private API, зафиксировать риск совместимости/отказа notarization/App Store; отключать при неизвестном OS build.
- Зависимости pin и scan, SBOM для будущих релизов; audit обновлятора; защищённые release tags.
- Настройки должны иметь schema version и graceful migration.

## Пользовательские гарантии
- Разрешение можно отозвать в System Settings; приложение должно degrade gracefully.
- «Показать всё», reset layout и safe mode; при невозможности операции честная ошибка.
- Аварийный флаг восстановления при старте.
- Crash не гарантирует graceful cleanup: проектировать так, чтобы отсутствие процесса не удерживало виртуальную шторку как единственную точку доступа.
- Проверка UI spoofing: панель не должна маскироваться под системный prompt или выманивать пароли.

## Security checklist перед release
- [ ] Нет системных команд `sudo`, инжекции, shell script с пользовательским вводом.
- [ ] Нет необязательных TCC prompts.
- [ ] Отозванный AX доступ не вызывает spin/retry loop.
- [ ] Нет полных путей/текстов окон в diagnostic bundle.
- [ ] Восстановление доступно без работы private backend.
- [ ] Release подпись и notarization проверены.
