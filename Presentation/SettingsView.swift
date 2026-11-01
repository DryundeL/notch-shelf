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
            requestedSectionCollapsed = false
            setMenuBarItems([])
            inventoryState = .permissionRequired
        }
    }
    @Published private(set) var visibilityMessage = L("Выберите обнаруженный значок после сканирования.")
    @Published private(set) var visibilityBusy = false
    @Published private(set) var hiddenCandidates: [MenuBarScanner.Candidate] = []
    @Published var pendingHiddenBundleIDs: Set<String> = []
    @Published private(set) var iconAvailableBundleIDs: Set<String> = []
    private let resourceIcons = MenuBarResourceIconProvider()
    private let iconAvailability: ((MenuBarScanner.Candidate) -> Bool)?
    private let accessibilityTrusted: () -> Bool
    @Published private(set) var visibilityNeedsExplicitRetry = false
    @Published private(set) var menuBarSectionCollapsed = false
    private var requestedSectionCollapsed = false
    private let nativeVisibility: any NativeVisibilityService
    private let installedApplication: () -> Bool
    private let runningProcesses: () -> [MenuBarScanner.Process]
    private let recovery: (any VisibilityRecoveryStore)?
    @Published private(set) var visibilityPausedAfterCrash: Bool
    private var visibilityGeneration = UUID()
    private var inventoryObservation: NSKeyValueObservation?
    var onHiddenItems: (([MenuBarScanner.Candidate]) -> Void)?
    var onInventoryChanged: (() -> Void)?
    var onSectionModeChanged: (() -> Void)?
    private let store: any SettingsStore

    init(store: any SettingsStore, loginItem: any LoginItemService = SystemLoginItemService(), recovery: (any VisibilityRecoveryStore)? = nil,
         iconAvailability: ((MenuBarScanner.Candidate) -> Bool)? = nil,
         accessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         nativeVisibility: any NativeVisibilityService = NSHNativeVisibility(),
         installedApplication: @escaping () -> Bool = { Bundle.main.bundleURL.path.hasPrefix("/Applications/") },
         runningProcesses: @escaping () -> [MenuBarScanner.Process] = {
             NSWorkspace.shared.runningApplications.map { .init(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier ?? "", name: $0.localizedName ?? "") }
         }) {
        self.nativeVisibility = nativeVisibility
        self.installedApplication = installedApplication
        self.runningProcesses = runningProcesses
        self.accessibilityTrusted = accessibilityTrusted
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
            errorMessage = L("Не удалось изменить автозапуск (%@, код %@). Проверьте раздел «Объекты входа» в системных настройках.", String(describing: failure.domain), String(describing: failure.code))
        }
    }

    func visibilityMessageForActivation(_ result: String) { visibilityMessage = result }

    func setMenuBarItems(_ items: [MenuBarScanner.Candidate]) {
        restoreVisibility(resetSection: false)
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

    func restoreVisibility(resetSection: Bool = true) {
        if resetSection { requestedSectionCollapsed = false }
        visibilityGeneration = UUID()
        inventoryObservation?.invalidate()
        inventoryObservation = nil
        nativeVisibility.restore()
        recovery?.clear()
        hiddenCandidates = []
        menuBarSectionCollapsed = false
        onHiddenItems?([])
        visibilityBusy = false
        visibilityMessage = L("Ограничение снято. Значки возвращены в системную строку.")
    }

    func revealAll() {
        restoreVisibility()
        update { $0.hiddenBundleIDs = []; $0.menuBarSectionBundleIDs = [] }
        if settings.hiddenBundleIDs.isEmpty { pendingHiddenBundleIDs = [] }
    }

    var availableSectionBundleIDs: Set<String> {
        NativeVisibilityPolicy.sectionBundleIDs(
            discovered: Set(menuBarItems.map(\.bundleID)).intersection(settings.menuBarSectionBundleIDs),
            shelf: Set(settings.hiddenBundleIDs), own: Bundle.main.bundleIdentifier ?? "")
    }

    @discardableResult
    func setSectionMembership(bundleID: String, hidden: Bool) -> Bool {
        guard settings.menuBarSectionEnabled, !visibilityBusy,
              menuBarItems.contains(where: { $0.bundleID == bundleID }),
              !bundleID.hasPrefix("com.apple."), bundleID != Bundle.main.bundleIdentifier,
              !settings.hiddenBundleIDs.contains(bundleID) else { return false }
        var ids = Set(settings.menuBarSectionBundleIDs)
        guard ids.contains(bundleID) != hidden else { return false }
        if hidden { ids.insert(bundleID) } else { ids.remove(bundleID) }
        update { $0.menuBarSectionBundleIDs = ids.sorted() }
        return Set(settings.menuBarSectionBundleIDs) == ids
    }

    @discardableResult
    func requireAccessibility() -> Bool {
        guard accessibilityTrusted() else {
            visibilityNeedsExplicitRetry = true
            beginInventoryRefresh(permissionGranted: false)
            visibilityMessage = L("Доступ Accessibility потерян. Значки возвращены. После выдачи доступа обновите список и нажмите «Применить выбор».")
            return false
        }
        return true
    }

    func applyHiddenApplications(saveSelection: Bool = true, sectionCollapsed: Bool? = nil) {
        guard !visibilityBusy else { return }
        if !saveSelection && sectionCollapsed == nil && (visibilityPausedAfterCrash || visibilityNeedsExplicitRetry) { return }
        guard requireAccessibility() else { return }
        guard inventoryState == .ready else {
            visibilityMessage = L("Нужен свежий список и разрешение Accessibility."); return
        }
        guard installedApplication() else {
            visibilityMessage = L("Запустите установленную копию из /Applications/NotchShelf.app."); return
        }
        refreshIconAvailability()
        let unsupported = Set(menuBarItems.map(\.bundleID)).subtracting(iconAvailableBundleIDs)
        let desired = (saveSelection ? pendingHiddenBundleIDs : Set(settings.hiddenBundleIDs)).subtracting(unsupported)
        let apps = runningProcesses()
        let live = menuBarItems.filter { item in
            desired.contains(item.bundleID) && iconAvailableBundleIDs.contains(item.bundleID) && apps.contains { $0.pid == item.pid && $0.bundleID == item.bundleID }
        }
        let selected = Set(live.map(\.bundleID))
        let collapseSection = settings.menuBarSectionEnabled && (sectionCollapsed ?? requestedSectionCollapsed)
        let own = Bundle.main.bundleIdentifier ?? ""
        let liveOwners = Set(menuBarItems.filter { item in
            apps.contains { $0.pid == item.pid && $0.bundleID == item.bundleID }
        }.map(\.bundleID))
        let sectionOwners = collapseSection ? NativeVisibilityPolicy.sectionBundleIDs(discovered: liveOwners.intersection(settings.menuBarSectionBundleIDs), shelf: Set(desired), own: own) : []
        let allSelected = selected.union(sectionOwners)
        restoreVisibility(resetSection: false)
        requestedSectionCollapsed = collapseSection
        guard !allSelected.isEmpty else {
            if saveSelection || desired != Set(settings.hiddenBundleIDs) { update { $0.hiddenBundleIDs = desired.sorted() } }
            return
        }
        guard !own.isEmpty,
              let allowed = NativeVisibilityPolicy.allowedBundleIDs(
                running: apps.map(\.bundleID).filter { !$0.isEmpty }, selected: allSelected, own: own) else {
            visibilityMessage = L("Некорректный выбор приложений. Обновите список."); return
        }
        var next = settings
        next.hiddenBundleIDs = desired.sorted()
        next.menuBarSectionBundleIDs.removeAll { desired.contains($0) }
        guard next.isValid else { visibilityMessage = L("Список приложений некорректен или превышает лимит 128."); return }
        visibilityGeneration = UUID()
        let generation = visibilityGeneration
        visibilityBusy = true
        visibilityMessage = L("Применяем выбор…")
        inventoryObservation = NSWorkspace.shared.observe(\.runningApplications, options: []) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.visibilityGeneration == generation,
                      Set(self.runningProcesses().map(\.pid)) != Set(apps.map(\.pid)) else { return }
                self.restoreVisibility(resetSection: false)
                self.onInventoryChanged?()
            }
        }
        let committedSettings = next
        recovery?.markActive()
        nativeVisibility.hide(withAllowedBundleIDs: allowed) { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, self.visibilityGeneration == generation else { return }
                guard self.requireAccessibility() else { return }
                guard Set(self.runningProcesses().map(\.pid)) == Set(apps.map(\.pid)) else {
                    self.restoreVisibility()
                    self.onInventoryChanged?()
                    return
                }
                if let message {
                    self.restoreVisibility()
                    self.visibilityNeedsExplicitRetry = true
                    self.visibilityMessage = message
                    return
                }
                if saveSelection || committedSettings.hiddenBundleIDs != self.settings.hiddenBundleIDs {
                    do { try self.store.save(committedSettings); self.settings = committedSettings }
                    catch {
                        self.restoreVisibility()
                        self.visibilityNeedsExplicitRetry = true
                        self.errorMessage = L("Не удалось сохранить выбор. Значки возвращены в строку меню.")
                        return
                    }
                }
                self.visibilityBusy = false
                self.visibilityPausedAfterCrash = false
                self.visibilityNeedsExplicitRetry = false
                self.hiddenCandidates = live
                self.menuBarSectionCollapsed = !sectionOwners.isEmpty
                self.onHiddenItems?(live)
                self.visibilityMessage = L("Приложений в шторке: %@. Наведите курсор на вырез или нажмите NS.", String(describing: selected.count))
                if !sectionOwners.isEmpty { self.visibilityMessage = L("Строка свёрнута: %@ приложений. Шторка: %@.", String(describing: sectionOwners.count), String(describing: selected.count)) }
            }
        }
    }

    func stop() { restoreVisibility(); displayProvider.stop() }

    func update(_ change: (inout ShelfSettings) -> Void) {
        let previousSectionMode = settings.menuBarSectionEnabled
        var next = settings
        change(&next)
        do {
            try store.save(next)
            settings = next
            errorMessage = nil
            if next.menuBarSectionEnabled != previousSectionMode { onSectionModeChanged?() }
        } catch SettingsStoreError.unsupportedVersion {
            errorMessage = L("Настройки созданы другой версией приложения. Изменения не сохранены, исходные данные оставлены без изменений.")
        } catch {
            errorMessage = L("Не удалось сохранить настройки. Изменение отменено.")
        }
    }
}

@MainActor
struct SettingsView: View {
    @AppStorage("shelf.language") private var language = "system"
    @ObservedObject var model: SettingsModel
    let scan: () -> Void
    let showReport: () -> Void
    let quit: () -> Void
    var applySelection: (() -> Void)? = nil
    var refreshInventory: (() -> Void)? = nil

    var body: some View {
        Form {
            Section(L("Общие")) {
                Picker(L("Язык приложения"), selection: $language) {
                    Text(L("Как в macOS")).tag("system")
                    Text("Русский").tag("ru")
                    Text("English").tag("en")
                }
                Text(L("Изменение языка применяется после перезапуска приложения.")).font(.caption)
                Toggle(L("Запускать при входе"), isOn: Binding(
                    get: { model.loginItemStatus.isRegistered },
                    set: { model.setLaunchAtLogin($0) }))
                if model.loginItemStatus == .requiresApproval {
                    Text(L("Автозапуск зарегистрирован, но требуется разрешение в системных настройках."))
                        .font(.caption)
                    Button(L("Открыть объекты входа")) { model.openLoginItemSettings() }
                } else if model.loginItemStatus == .notFound {
                    Text(L("macOS пока не находит службу автозапуска. Попробуйте включить её; при отказе будет показан код ошибки.")).font(.caption)
                }
            }
            Section(L("Оформление")) {
                Picker(L("Положение панели"), selection: Binding(
                    get: { model.settings.defaultDisplayMode },
                    set: { value in model.update { $0.defaultDisplayMode = value } })) {
                    Text(L("Автоматически")).tag(ShelfSettings.DisplayMode.automatic)
                    Text(L("Под значком")).tag(ShelfSettings.DisplayMode.floating)
                }
                Toggle(L("Анимация панели"), isOn: Binding(
                    get: { model.settings.animationsEnabled },
                    set: { value in model.update { $0.animationsEnabled = value } }))
                Stepper(L("Длительность: %@ мс", String(describing: model.settings.animationDurationMs)), value: Binding(
                    get: { model.settings.animationDurationMs },
                    set: { value in model.update { $0.animationDurationMs = value } }), in: 1...1000, step: 10)
                    .disabled(!model.settings.animationsEnabled)
            }
            Section(L("Дисплеи")) {
                ForEach(model.displays, id: \.runtimeID) { display in
                    if let key = display.profileKey, model.displays.filter({ $0.profileKey == key }).count == 1 {
                        Picker(display.name, selection: Binding(
                            get: { model.settings.perDisplayModes[key]?.rawValue ?? "inherit" },
                            set: { value in model.update { $0.perDisplayModes[key] = ShelfSettings.DisplayMode(rawValue: value) } })) {
                            Text(L("Общее положение")).tag("inherit")
                            Text(L("Автоматически")).tag("automatic")
                            if display.hasNotch { Text(L("Под вырезом")).tag("notch") }
                            Text(L("Под значком")).tag("floating")
                            Text(L("Минимальный")).tag("minimal")
                        }
                    } else {
                        LabeledContent(display.name, value: L("Под значком — профиль недоступен"))
                    }
                }
                Text(L("Минимальный режим открывает настройки без панели. Изменения применяются при следующем клике по значку."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Режим строки меню")) {
                Toggle(L("Разрешить скрытие через Command-перетаскивание"), isOn: Binding(
                    get: { model.settings.menuBarSectionEnabled },
                    set: { value in model.update { $0.menuBarSectionEnabled = value } }))
                Text(L("Удерживая Command, перенесите значок влево от NotchShelf, чтобы добавить его в скрываемую группу, или вправо, чтобы убрать. ЛКМ раскрывает группу, ПКМ открывает меню. Стрелка появляется только для непустой группы."))
                    .font(.caption)
            }
            Section(L("Приложения в шторке")) {
                Text(L("Выберите приложения, которые нужно убрать из строки меню. Их значки будут доступны в шторке."))
                    .font(.caption)
                if model.visibilityPausedAfterCrash {
                    Text(L("Предыдущий сеанс завершился некорректно. Значки оставлены видимыми; для продолжения нажмите «Применить выбор»."))
                        .font(.caption)
                }
                if let refreshInventory {
                    Button(model.inventoryState == .permissionRequired ? L("Разрешить доступ и найти приложения…") : L("Обновить список приложений"), action: refreshInventory)
                        .disabled(model.inventoryState == .scanning || model.visibilityBusy)
                }
                switch model.inventoryState {
                case .scanning:
                    ProgressView(L("Ищем значки в строке меню…"))
                case .permissionRequired:
                    Text(L("Нужен доступ Accessibility. После выдачи разрешения список обновится при возвращении в настройки."))
                        .font(.caption)
                case .empty:
                    Text(L("Доступных для открытия значков не найдено. Проверьте Accessibility для установленной копии Notch Shelf и обновите список. Подробности — в отчёте диагностики."))
                        .font(.caption)
                case .notLoaded:
                    Text(L("Нажмите «Обновить список приложений».")).font(.caption)
                case .ready:
                    Text(L("Доступных значков: %@", String(describing: model.menuBarItems.count))).font(.caption)
                }
                ForEach(Array(Set(model.menuBarItems.map(\.bundleID)).union(model.pendingHiddenBundleIDs)).sorted(), id: \.self) { bundleID in
                    let item = model.menuBarItems.first(where: { $0.bundleID == bundleID })
                        Toggle(isOn: Binding(
                            get: { model.pendingHiddenBundleIDs.contains(bundleID) },
                            set: { if $0 && model.iconAvailableBundleIDs.contains(bundleID) { model.pendingHiddenBundleIDs.insert(bundleID) } else { model.pendingHiddenBundleIDs.remove(bundleID) } })) {
                            VStack(alignment: .leading) {
                                Text(item.flatMap { NSRunningApplication(processIdentifier: $0.pid)?.localizedName } ?? L("%@ — не найдено", String(describing: bundleID)))
                                if !model.iconAvailableBundleIDs.contains(bundleID) {
                                    Text(L("Значок недоступен — скрытие отключено")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.disabled(model.visibilityBusy || !model.iconAvailableBundleIDs.contains(bundleID) || bundleID.hasPrefix("com.apple.") || bundleID == Bundle.main.bundleIdentifier)
                }
                Text(L("Скрыть можно только приложения, для которых найден значок в ресурсах владельца, без записи экрана. Если значок недоступен или неоднозначен, приложение остаётся в строке меню. Динамические состояния пока не синхронизируются."))
                    .font(.caption)
                Button(L("Применить выбор")) { if let applySelection { applySelection() } else { model.applyHiddenApplications() } }
                    .disabled(model.visibilityBusy || model.inventoryState != .ready)
                Button(L("Вернуть все значки")) { model.revealAll() }
                Text(model.visibilityMessage).font(.caption)
            }
            Section(L("Диагностика")) {
                Button(L("Сканировать значки…"), action: scan)
                Button(L("Показать отчёт"), action: showReport)
            }
            Section {
                Button(L("Выйти из Notch Shelf"), action: quit)
            }
        }
        .onAppear { model.refreshLoginItem() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshLoginItem()
            if model.inventoryState == .permissionRequired && AXIsProcessTrusted() { refreshInventory?() }
        }
        .formStyle(.grouped)
        .frame(minWidth: 500, minHeight: 420)
        .alert(L("Не удалось применить изменение"), isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK") { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
    }
}
