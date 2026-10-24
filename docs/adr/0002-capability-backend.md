# ADR-0002: MenuBarBackend с capability negotiation

**Status:** Accepted.

## Context
Нет публичного универсального API для контроля сторонних status items; OS behavior меняется.

## Decision
Порт с typed capabilities/errors и сменяемыми адаптерами. Public-safe fallback всегда доступен. Private adapter экспериментален и gated by OS build.

## Consequences
UI обязан различать supported/unsupported. Функция «скрыть любой значок» не обещается до PoC. Можно отключать опасный backend без переписывания Presentation.
