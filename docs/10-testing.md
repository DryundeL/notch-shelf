# QA: тест-план и проверка на реальных системах

## Unit
- RuleEngine rules precedence; unknown items -> safe default.
- State machine rapid click, close/open, cancellation.
- Geometry tests for negative origin, rotated monitors, mixed DPI, clamping.
- Settings migration, bad JSON, corrupted config, rollback.
- Reconciliation handles duplicate and disappearing item IDs.

## Integration
- Own NSStatusItem lifetime.
- Backend capabilities vs actual OS.
- AX trust absent / granted / revoked while running.
- Click original item vs reveal fallback.
- Hotkeys conflicts and keyboard-only navigation.
- Launch at Login status, register/unregister.
- App termination + restart + interrupted shutdown.

## Manual display matrix
| Case | Required |
|---|---|
| Built-in notch only | yes |
| Built-in + HDMI/USB-C external | yes |
| Two externals | yes |
| external becomes primary | yes |
| mirrored displays | yes |
| mixed scaling | yes |
| display hot unplug while open | yes |
| sleep/wake / clamshell | yes |
| Full Screen and Spaces | yes |
| auto-hide menu bar | yes |
| menu bar crowded / app menus overlap | yes |

## Fault injection
- Kill -9 process during hidden state (safe recovery on next launch).
- Restart WindowServer only in safe test environment.
- Disable AX and screen recording mid-session.
- Unknown macOS build => private backend disabled.
- Permission dialog appears while panel open.
- Item owner app quits/relaunches repeatedly.
- Memory pressure while cache filled.

## Performance suite
5 min idle + 100 panel cycles + 10 monitor topology changes; compare measurements to `07-performance.md`.

## Release acceptance
- No unrecoverable invisible icon state in supported configurations.
- No crash with concurrent display changes and hotkey.
- No forced AX or Recording prompt at first launch.
- VoiceOver usable; Escape and Reveal All function.
- UI reacts to `Reduce Motion`.
- All P0 acceptance conditions in `01-product-requirements.md` passed.
