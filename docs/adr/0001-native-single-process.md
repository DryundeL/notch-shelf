# ADR-0001: Нативный один процесс

**Status:** Accepted for initial architecture.

## Context
Утилита постоянно работает в фоне, крайне чувствительна к RSS, CPU wakeups и window behavior.

## Decision
Swift/AppKit, один agent process, SwiftUI только для lazy settings; нет XPC/helper/backend пока нет доказанной потребности.

## Consequences
Низкий overhead, простая упаковка и debugging. Цена — необходимость дисциплины main actor и изоляции системных вызовов от UI.
