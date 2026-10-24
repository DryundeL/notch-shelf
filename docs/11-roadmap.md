# План работ и backlog

## Phase 0 — Feasibility gate (блокирует остальные)
- [ ] Подтвердить exact macOS build и deployment baseline.
- [ ] Own status item + sections prototype.
- [ ] Test AX discovery on 6–10 apps.
- [ ] Test original native item activation vs reveal fallback.
- [ ] Measure initial RAM/CPU on Apple M4.
- [ ] Multi-display hotplug test.
**Go/no-go:** если перенос/активация чужих items неустойчивы, зафиксировать supported reduced scope (native reveal) вместо фейковой реализации.

## Phase 1 — Core
- [ ] App lifecycle, single process, coordinator, typed errors.
- [ ] Backend protocol + safe fallback implementation.
- [ ] Visibility/reveal operations, recovery action.
- [ ] UserDefaults schemas/migrations.
- [ ] ServiceManagement login item.

## Phase 2 — Panel
- [ ] Lazy reusable NSPanel.
- [ ] Click, Escape, outside click, accessible focus.
- [ ] Notch anchor, floating anchor, minimal section mode.
- [ ] Animation toggle + Reduced Motion.

## Phase 3 — Displays
- [ ] NSScreen/CG snapshots and callbacks.
- [ ] Active display policy.
- [ ] Hotplug/clamshell/mirroring tests.
- [ ] Per-display profiles.

## Phase 4 — Automation
- [ ] Rule engine and new item detection (best effort).
- [ ] Exclusions, pinned items, rule migrations.
- [ ] Hover zone and hotkeys.
- [ ] Permission management.

## Phase 5 — Release hardening
- [ ] Memory/CPU gates, crash-recovery, negative tests.
- [ ] Hardened runtime entitlements audit.
- [ ] Developer ID signing + notarization.
- [ ] Privacy policy and permissions UX.
- [ ] Version compatibility matrix, limitations clearly disclosed.

## Definition of Done для задачи
- Unit/integration tests проходят.
- AppKit операции на main thread.
- Нет новых необоснованных разрешений.
- Есть manual verification on relevant monitors.
- Error state safe + user recovery documented.
- Нет видимой регрессии latency/footprint.
- Документация и capability matrix обновлены.
