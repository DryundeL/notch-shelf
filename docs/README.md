# Документация Notch Shelf

Все пути исходников и будущих артефактов в документах указываются относительно корня репозитория.
Папки приложения находятся в корне, документы — внутри `docs/`.

## Спецификация

- [Требования](01-product-requirements.md)
- [Стек](02-tech-stack.md) и [зависимости](DEPENDENCIES.md)
- [Архитектура](03-architecture.md)
- [Движок menu bar](04-menu-bar-engine.md)
- [Несколько мониторов](05-multi-monitor.md)
- [Безопасность и приватность](06-security-privacy.md)
- [Производительность](07-performance.md)
- [UX и настройки](08-ux-settings.md)
- [Модели и интерфейсы](09-domain-and-interfaces.md)
- [Проверки](10-testing.md)
- [Дорожная карта](11-roadmap.md)
- [Сборка и выпуск](12-build-release.md)
- [Риски](13-risks.md)

## Решения и задачи

- [Архитектурные решения](adr/)
- [План](tasks/plan.md)
- [Задачи и критерии приёмки](tasks/todo.md)

## Назначение папок

- [App](structure/App.md)
- [Domain](structure/Domain.md)
- [Ports](structure/Ports.md)
- [Infrastructure](structure/Infrastructure.md)
- [Presentation](structure/Presentation.md)
- [Resources](structure/Resources.md)
- [Unit-тесты](structure/NotchShelfTests.md)
- [UI-тесты](structure/NotchShelfUITests.md)

## Будущие результаты проверок

`docs/capability-matrix.md` появится в задачах 2–5: OS build, дисплей, works/partial/no,
ограничения и решение go/no-go. Замеры CPU, phys_footprint и wakeups будут записаны
в `docs/PERF.md` в задаче 4. Пока эти проверки не выполнялись.
