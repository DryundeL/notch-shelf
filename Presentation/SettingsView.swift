import SwiftUI
import ApplicationServices

@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var settings: ShelfSettings
    @Published var errorMessage: String?
    @Published private(set) var displays: [DisplaySnapshot] = []
    private let displayProvider = ScreenDisplayProvider()
    @Published private(set) var loginItemStatus: LoginItemStatus
    private let loginItem: any LoginItemService
    @Published private(set) var menuBarItems: [MenuBarScanner.Candidate] = []
    @Published var selectedMenuBarItem: UUID?
    enum InventoryState: Equatable { case notLoaded, scanning, permissionRequired, ready, empty }
    @Published private(set) var inventoryState: InventoryState = .notLoaded

    func beginInventoryRefresh(permissionGranted: Bool) {
        inventoryState = permissionGranted ? .scanning : .permissionRequired
        if !permissionGranted {
            setMenuBarItems([])
            inventoryState = .permissionRequired
        }
    }
    @Published private(set) var visibilityMessage = "Выберите обнаруженный значок после сканирования."
    @Published private(set) var visibilityBusy = false
    @Published private(set) var hiddenCandidates: [MenuBarScanner.Candidate] = []
    @Published var pendingHiddenBundleIDs: Set<String> = []
    @Published private(set) var iconAvailableBundleIDs: Set<String> = []
    private let resourceIcons = MenuBarResourceIconProvider()
    private let iconAvailability: ((MenuBarScanner.Candidate) -> Bool)?
    private let nativeVisibility = NSHNativeVisibility()
    private let recovery: (any VisibilityRecoveryStore)?
    @Published private(set) var visibilityPausedAfterCrash: Bool
    private var visibilityGeneration = UUID()
    private var inventoryObservation: NSKeyValueObservation?
    var onHiddenItems: (([MenuBarScanner.Candidate]) -> Void)?
    var onInventoryChanged: (() -> Void)?
    private let store: any SettingsStore

    init(store: any SettingsStore, loginItem: any LoginItemService = SystemLoginItemService(), recovery: (any VisibilityRecoveryStore)? = nil,
         iconAvailability: ((MenuBarScanner.Candidate) -> Bool)? = nil) {
        self.iconAvailability = iconAvailability
        self.recovery = recovery
        visibilityPausedAfterCrash = recovery?.requiresRecovery ?? false
        self.loginItem = loginItem
        loginItemStatus = loginItem.status
        self.store = store
        settings = store.load()
        pendingHiddenBundleIDs = Set(settings.hiddenBundleIDs)
        displays = displayProvider.snapshots
        displayProvider.onChange = { [weak self] in self?.displays = $0 }
    }

    func refreshLoginItem() { loginItemStatus = loginItem.status }

    func openLoginItemSettings() { loginItem.openSettings() }

    func setLaunchAtLogin(_ enabled: Bool) {
        refreshLoginItem()
        guard enabled != loginItemStatus.isRegistered else { return }
        do {
            try loginItem.setEnabled(enabled)
            refreshLoginItem()
            update { $0.launchAtLogin = loginItemStatus.isRegistered }
        } catch {
            refreshLoginItem()
            let failure = error as NSError
            errorMessage = "Не удалось изменить автозапуск (\(failure.domain), код \(failure.code)). Проверьте раздел «Объекты входа» в системных настройках."
        }
    }

    func visibilityMessageForActivation(_ result: String) { visibilityMessage = result }

    func setMenuBarItems(_ items: [MenuBarScanner.Candidate]) {
        restoreVisibility()
        let previousSelection = selectedMenuBarItem
        menuBarItems = items
        refreshIconAvailability()
        selectedMenuBarItem = items.contains(where: { $0.id == previousSelection }) ? previousSelection : items.first?.id
        inventoryState = items.isEmpty ? .empty : .ready
    }

    private func refreshIconAvailability() {
        resourceIcons.invalidate()
        iconAvailableBundleIDs = Set(menuBarItems.filter { item in
            if let iconAvailability { return iconAvailability(item) }
            guard let app = NSRunningApplication(processIdentifier: item.pid),
                  app.bundleIdentifier == item.bundleID, let url = app.bundleURL else { return false }
            return resourceIcons.image(bundleID: item.bundleID, bundleURL: url) != nil
        }.map(\.bundleID))
        let unsupported = Set(menuBarItems.map(\.bundleID)).subtracting(iconAvailableBundleIDs)
        pendingHiddenBundleIDs.subtract(unsupported)
    }

    func restoreVisibility() {
        visibilityGeneration = UUID()
        inventoryObservation?.invalidate()
        inventoryObservation = nil
        nativeVisibility.restore()
        recovery?.clear()
        hiddenCandidates = []
        onHiddenItems?([])
        visibilityBusy = false
        visibilityMessage = "Ограничение снято. Значки возвращены в системную строку."
    }

    func revealAll() {
        restoreVisibility()
        update { $0.hiddenBundleIDs = [] }
        if settings.hiddenBundleIDs.isEmpty { pendingHiddenBundleIDs = [] }
    }

    func applyHiddenApplications(saveSelection: Bool = true) {
        guard !visibilityBusy else { return }
        if !saveSelection && visibilityPausedAfterCrash { return }
        guard AXIsProcessTrusted(), inventoryState == .ready else {
            visibilityMessage = "Нужен свежий список и разрешение Accessibility."; return
        }
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else {
            visibilityMessage = "Запустите установленную копию из /Applications/NotchShelf.app."; return
        }
        refreshIconAvailability()
        let unsupported = Set(menuBarItems.map(\.bundleID)).subtracting(iconAvailableBundleIDs)
        let desired = (saveSelection ? pendingHiddenBundleIDs : Set(settings.hiddenBundleIDs)).subtracting(unsupported)
        let apps = NSWorkspace.shared.runningApplications
        let live = menuBarItems.filter { item in
            desired.contains(item.bundleID) && iconAvailableBundleIDs.contains(item.bundleID) && apps.contains { $0.processIdentifier == item.pid && $0.bundleIdentifier == item.bundleID }
        }
        let selected = Set(live.map(\.bundleID))
        restoreVisibility()
        guard !selected.isEmpty else {
            if saveSelection || desired != Set(settings.hiddenBundleIDs) { update { $0.hiddenBundleIDs = desired.sorted() } }
            return
        }
        guard let own = Bundle.main.bundleIdentifier,
              let allowed = NativeVisibilityPolicy.allowedBundleIDs(
                running: apps.compactMap(\.bundleIdentifier), selected: selected, own: own) else {
            visibilityMessage = "Некорректный выбор приложений. Обновите список."; return
        }
        var next = settings
        next.hiddenBundleIDs = desired.sorted()
        guard next.isValid else { visibilityMessage = "Список приложений некорректен или превышает лимит 128."; return }
        visibilityGeneration = UUID()
        let generation = visibilityGeneration
        visibilityBusy = true
        visibilityMessage = "Применяем выбор…"
        inventoryObservation = NSWorkspace.shared.observe(\.runningApplications, options: []) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.visibilityGeneration == generation,
                      Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier)) != Set(apps.map(\.processIdentifier)) else { return }
                self.restoreVisibility()
                self.onInventoryChanged?()
            }
        }
        let committedSettings = next
        recovery?.markActive()
        nativeVisibility.hide(withAllowedBundleIDs: allowed) { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, self.visibilityGeneration == generation else { return }
                if let message {
                    self.restoreVisibility()
                    self.visibilityMessage = message
                    return
                }
                if saveSelection || committedSettings.hiddenBundleIDs != self.settings.hiddenBundleIDs {
                    do { try self.store.save(committedSettings); self.settings = committedSettings }
                    catch {
                        self.restoreVisibility()
                        self.errorMessage = "Не удалось сохранить выбор. Значки возвращены в строку меню."
                        return
                    }
                }
                self.visibilityBusy = false
                self.visibilityPausedAfterCrash = false
                self.hiddenCandidates = live
                self.onHiddenItems?(live)
                self.visibilityMessage = "Приложений в шторке: \(selected.count). Наведите курсор на вырез или нажмите NS."
            }
        }
    }

    func stop() { restoreVisibility(); displayProvider.stop() }

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
    var applySelection: (() -> Void)? = nil
    var refreshInventory: (() -> Void)? = nil
    var revealSection: (() -> Void)? = nil

    var body: some View {
        Form {
            Section("Общие") {
                Toggle("Запускать при входе", isOn: Binding(
                    get: { model.loginItemStatus.isRegistered },
                    set: { model.setLaunchAtLogin($0) }))
                if model.loginItemStatus == .requiresApproval {
                    Text("Автозапуск зарегистрирован, но требуется разрешение в системных настройках.")
                        .font(.caption)
                    Button("Открыть объекты входа") { model.openLoginItemSettings() }
                } else if model.loginItemStatus == .notFound {
                    Text("macOS пока не находит службу автозапуска. Попробуйте включить её; при отказе будет показан код ошибки.").font(.caption)
                }
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
            if let revealSection {
                Section("Экспериментальная секция") {
                    Button("Вернуть все значки", action: revealSection)
                    Text("Старый эксперимент разделителя. Клики по NS открывают и закрывают шторку; настройки доступны через шестерёнку.")
                        .font(.caption)
                }
            }
            Section("Приложения в шторке") {
                Text("Выберите приложения, которые нужно убрать из строки меню. Их значки будут доступны в шторке.")
                    .font(.caption)
                if model.visibilityPausedAfterCrash {
                    Text("Предыдущий сеанс завершился некорректно. Значки оставлены видимыми; для продолжения нажмите «Применить выбор».")
                        .font(.caption)
                }
                if let refreshInventory {
                    Button(model.inventoryState == .permissionRequired ? "Разрешить доступ и найти приложения…" : "Обновить список приложений", action: refreshInventory)
                        .disabled(model.inventoryState == .scanning || model.visibilityBusy)
                }
                switch model.inventoryState {
                case .scanning:
                    ProgressView("Ищем значки в строке меню…")
                case .permissionRequired:
                    Text("Нужен доступ Accessibility. После выдачи разрешения список обновится при возвращении в настройки.")
                        .font(.caption)
                case .empty:
                    Text("Доступных для открытия значков не найдено. Проверьте Accessibility для установленной копии Notch Shelf и обновите список. Подробности — в отчёте диагностики.")
                        .font(.caption)
                case .notLoaded:
                    Text("Нажмите «Обновить список приложений».").font(.caption)
                case .ready:
                    Text("Доступных значков: \(model.menuBarItems.count)").font(.caption)
                }
                ForEach(Array(Set(model.menuBarItems.map(\.bundleID)).union(model.pendingHiddenBundleIDs)).sorted(), id: \.self) { bundleID in
                    let item = model.menuBarItems.first(where: { $0.bundleID == bundleID })
                        Toggle(isOn: Binding(
                            get: { model.pendingHiddenBundleIDs.contains(bundleID) },
                            set: { if $0 && model.iconAvailableBundleIDs.contains(bundleID) { model.pendingHiddenBundleIDs.insert(bundleID) } else { model.pendingHiddenBundleIDs.remove(bundleID) } })) {
                            VStack(alignment: .leading) {
                                Text(item.flatMap { NSRunningApplication(processIdentifier: $0.pid)?.localizedName } ?? "\(bundleID) — не найдено")
                                if !model.iconAvailableBundleIDs.contains(bundleID) {
                                    Text("Значок недоступен — скрытие отключено").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.disabled(model.visibilityBusy || !model.iconAvailableBundleIDs.contains(bundleID) || bundleID.hasPrefix("com.apple.") || bundleID == Bundle.main.bundleIdentifier)
                }
                Text("Скрыть можно только приложения, для которых найден значок в ресурсах владельца, без записи экрана. Если значок недоступен или неоднозначен, приложение остаётся в строке меню. Динамические состояния пока не синхронизируются.")
                    .font(.caption)
                Button("Применить выбор") { if let applySelection { applySelection() } else { model.applyHiddenApplications() } }
                    .disabled(model.visibilityBusy || model.inventoryState != .ready)
                Button("Вернуть все значки") { model.revealAll() }
                Text(model.visibilityMessage).font(.caption)
            }
            Section("Диагностика") {
                Button("Сканировать значки…", action: scan)
                Button("Показать отчёт", action: showReport)
            }
            Section {
                Button("Выйти из Notch Shelf", action: quit)
            }
        }
        .onAppear { model.refreshLoginItem() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshLoginItem()
            if model.inventoryState == .permissionRequired && AXIsProcessTrusted() { refreshInventory?() }
        }
        .formStyle(.grouped)
        .frame(minWidth: 500, minHeight: 420)
        .alert("Не удалось применить изменение", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK") { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
    }
}
