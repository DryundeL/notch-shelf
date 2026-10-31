import SwiftUI

@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var settings: ShelfSettings
    @Published var errorMessage: String?
    @Published private(set) var displays: [DisplaySnapshot] = []
    private let displayProvider = ScreenDisplayProvider()
    private let store: any SettingsStore

    init(store: any SettingsStore) {
        self.store = store
        settings = store.load()
        displays = displayProvider.snapshots
        displayProvider.onChange = { [weak self] in self?.displays = $0 }
    }

    func stop() { displayProvider.stop() }

    func update(_ change: (inout ShelfSettings) -> Void) {
        var next = settings
        change(&next)
        do {
            try store.save(next)
            settings = next
            errorMessage = nil
        } catch SettingsStoreError.unsupportedVersion {
            errorMessage = "Настройки созданы другой версией приложения. Изменения не сохранены, исходные данные оставлены без изменений."
        } catch {
            errorMessage = "Не удалось сохранить настройки. Изменение отменено."
        }
    }
}

@MainActor
struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    let scan: () -> Void
    let showReport: () -> Void
    let quit: () -> Void

    var body: some View {
        Form {
            Section("Общие") {
                Toggle("Запускать при входе", isOn: .constant(false))
                    .disabled(true)
                    .help("Автозапуск пока недоступен в этой версии.")
            }
            Section("Оформление") {
                Picker("Положение панели", selection: Binding(
                    get: { model.settings.defaultDisplayMode },
                    set: { value in model.update { $0.defaultDisplayMode = value } })) {
                    Text("Автоматически").tag(ShelfSettings.DisplayMode.automatic)
                    Text("Под значком").tag(ShelfSettings.DisplayMode.floating)
                }
                Toggle("Анимация панели", isOn: Binding(
                    get: { model.settings.animationsEnabled },
                    set: { value in model.update { $0.animationsEnabled = value } }))
                Stepper("Длительность: \(model.settings.animationDurationMs) мс", value: Binding(
                    get: { model.settings.animationDurationMs },
                    set: { value in model.update { $0.animationDurationMs = value } }), in: 1...1000, step: 10)
                    .disabled(!model.settings.animationsEnabled)
            }
            Section("Дисплеи") {
                ForEach(model.displays, id: \.runtimeID) { display in
                    if let key = display.profileKey, model.displays.filter({ $0.profileKey == key }).count == 1 {
                        Picker(display.name, selection: Binding(
                            get: { model.settings.perDisplayModes[key]?.rawValue ?? "inherit" },
                            set: { value in model.update { $0.perDisplayModes[key] = ShelfSettings.DisplayMode(rawValue: value) } })) {
                            Text("Общее положение").tag("inherit")
                            Text("Автоматически").tag("automatic")
                            if display.hasNotch { Text("Под вырезом").tag("notch") }
                            Text("Под значком").tag("floating")
                            Text("Минимальный").tag("minimal")
                        }
                    } else {
                        LabeledContent(display.name, value: "Под значком — профиль недоступен")
                    }
                }
                Text("Минимальный режим открывает настройки без панели. Изменения применяются при следующем клике по значку.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Диагностика") {
                Button("Сканировать значки…", action: scan)
                Button("Показать отчёт", action: showReport)
            }
            Section {
                Button("Выйти из Notch Shelf", action: quit)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 500, minHeight: 420)
        .alert("Настройки не сохранены", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK") { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
    }
}
