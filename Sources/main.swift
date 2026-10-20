import AppKit
import ServiceManagement

struct WindowQuota {
    let remaining: Int
    let reset: Date?
    let minutes: Int
    init?(_ raw: Any?) {
        guard let d = raw as? [String: Any], let used = d["usedPercent"] as? Double,
              used.isFinite, used >= 0,
              let duration = d["windowDurationMins"] as? Int, duration > 0 else { return nil }
        remaining = Int(max(0, min(100, 100 - used)).rounded(.down))
        minutes = duration
        if let epoch = d["resetsAt"] as? Double { reset = Date(timeIntervalSince1970: epoch) } else { reset = nil }
    }
}

final class QuotaClient {
    var onResult: (([String: Any]?, String?) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var ready = false
    private var pending: Int?
    private var nextID = 10
    private var generation = 0
    private var deadline: DispatchWorkItem?
    private var executable: String? {
        let env = ProcessInfo.processInfo.environment
        if let override = env["CODEX_CLI_PATH"], FileManager.default.isExecutableFile(atPath: override) { return override }
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        ]
        let search = (env["PATH"] ?? "/usr/bin:/bin").components(separatedBy: ":") + ["/opt/homebrew/bin", "/usr/local/bin"]
        return (candidates + search.filter { !$0.isEmpty }.map { $0 + "/codex" }).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func refresh() {
        guard pending == nil else { return }
        if process?.isRunning == true && ready { requestQuota(); return }
        stop()
        generation += 1
        let gen = generation
        guard let executable = executable else { fail("Codex CLI не найден. Установи Codex и войди в аккаунт."); return }
        let proc = Process(), stdin = Pipe(), stdout = Pipe()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = ["app-server", "--listen", "stdio://"]
        proc.standardInput = stdin; proc.standardOutput = stdout
        proc.standardError = FileHandle.nullDevice
        process = proc; input = stdin.fileHandleForWriting
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                guard let self = self, self.generation == gen else { return }
                if data.isEmpty { self.fail("Соединение с Codex закрыто"); return }
                self.consume(data)
            }
        }
        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.generation == gen else { return }
                self.fail("Сервис Codex остановлен")
            }
        }
        do {
            try proc.run()
            let info: [String: Any] = ["name": "codex_limit_indicator", "title": "Codex Limits", "version": "1.0.0"]
            let params: [String: Any] = ["clientInfo": info, "capabilities": ["experimentalApi": true]]
            send(["id": 1, "method": "initialize", "params": params])
            armTimeout()
        } catch { fail("Не удалось запустить Codex CLI") }
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        do { try input?.write(contentsOf: data + Data([10])) }
        catch { fail("Ошибка соединения с Codex") }
    }
    private func requestQuota() {
        nextID += 1; pending = nextID
        armTimeout()
        send(["id": nextID, "method": "account/rateLimits/read", "params": ["excludeResetCreditDetails": true]])
    }
    private func armTimeout() {
        deadline?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fail("Codex не ответил за 25 секунд") }
        deadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: work)
    }
    private func consume(_ data: Data) {
        buffer.append(data)
        if buffer.count > 2_000_000 { fail("Некорректный ответ Codex"); return }
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: end); buffer.removeSubrange(...end)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = object["id"] as? Int else { continue }
            if object["error"] != nil { fail("Не удалось прочитать лимиты. Проверь вход в Codex."); return }
            if id == 1 {
                deadline?.cancel(); ready = true
                send(["method": "initialized", "params": [:]])
                requestQuota()
            } else if id == pending {
                deadline?.cancel(); pending = nil
                guard let result = object["result"] as? [String: Any] else { fail("Пустой ответ о лимитах"); return }
                onResult?(result, nil)
            }
        }
    }
    private func fail(_ message: String) { stop(); onResult?(nil, message) }
    func stop() {
        generation += 1; deadline?.cancel(); deadline = nil
        ready = false; pending = nil; buffer.removeAll()
        if let proc = process {
            (proc.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            proc.terminationHandler = nil
            try? input?.close()
            if proc.isRunning { proc.terminate() }
        }
        input = nil; process = nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let client = QuotaClient()
    private var item: NSStatusItem!
    private let menu = NSMenu()
    private let loginItem = NSMenuItem(title: "Запускать при входе в macOS", action: #selector(toggleLogin), keyEquivalent: "")
    private let loginSettingsItem = NSMenuItem(title: "Разрешить автозапуск в настройках…", action: #selector(openLoginSettings), keyEquivalent: "")
    private let primaryLine = NSMenuItem(title: "Получение лимита…", action: nil, keyEquivalent: "")
    private let resetLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let weeklyLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let updateLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let errorLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var quota: WindowQuota?
    private var weekly: WindowQuota?
    private var updated: Date?
    private var errorMessage: String?
    private var timer: Timer?
    private let probe = CommandLine.arguments.contains("--probe")

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !probe {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: nil)
            item.button?.imagePosition = .imageLeading
            item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            item.button?.setAccessibilityLabel("Остаток пятичасового лимита Codex")
            menu.addItem(NSMenuItem(title: "Codex Limits · остаток лимита", action: nil, keyEquivalent: ""))
            menu.addItem(.separator())
            for line in [primaryLine, resetLine, weeklyLine, updateLine, errorLine] { menu.addItem(line) }
            menu.addItem(.separator())
            loginItem.target = self; menu.addItem(loginItem)
            loginSettingsItem.target = self; menu.addItem(loginSettingsItem)
            updateLoginState()
            menu.addItem(.separator())
            let refresh = NSMenuItem(title: "Обновить", action: #selector(refreshNow), keyEquivalent: "r"); refresh.target = self; menu.addItem(refresh)
            let quit = NSMenuItem(title: "Завершить Codex Limits", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
            item.menu = menu
            render()
        }
        client.onResult = { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                let buckets = result["rateLimitsByLimitId"] as? [String: Any]
                let raw = (buckets?["codex"] as? [String: Any]) ?? (result["rateLimits"] as? [String: Any])
                let windows = [WindowQuota(raw?["primary"]), WindowQuota(raw?["secondary"])].compactMap { $0 }
                if let fiveHour = windows.first(where: { $0.minutes == 300 }) {
                    self.quota = fiveHour
                    self.weekly = windows.first(where: { $0.minutes == 10080 })
                    self.updated = Date(); self.errorMessage = nil
                } else { self.errorMessage = "Пятичасовой лимит недоступен" }
            } else { self.errorMessage = error ?? "Лимит недоступен" }
            if self.probe {
                if self.errorMessage == nil, let q = self.quota {
                    print("5h remaining: \(q.remaining)%; weekly: \(self.weekly.map { String($0.remaining) } ?? "unknown")%; source: account/rateLimits/read")
                    self.client.stop(); exit(0)
                } else { print(self.errorMessage ?? "Ошибка"); self.client.stop(); exit(1) }
            }
            self.render()
        }
        client.refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.render(); self?.client.refresh() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wokeUp), name: NSWorkspace.didWakeNotification, object: nil)
    }
    private func format(_ date: Date) -> String {
        let df = DateFormatter(); df.locale = Locale(identifier: "ru_RU"); df.dateFormat = "dd.MM HH:mm"; return df.string(from: date)
    }
    private func updateLoginState() {
        let status = SMAppService.mainApp.status
        loginItem.state = status == .enabled ? .on : (status == .requiresApproval ? .mixed : .off)
        loginSettingsItem.isHidden = status != .requiresApproval
    }
    @objc private func toggleLogin() {
        do {
            let status = SMAppService.mainApp.status
            if status == .enabled || status == .requiresApproval { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Не удалось изменить автозапуск"
            alert.informativeText = "Перенеси Codex Limits в Applications и попробуй снова. macOS может запросить разрешение в настройках объектов входа."
            alert.addButton(withTitle: "Понятно")
            alert.runModal()
        }
        updateLoginState()
    }
    @objc private func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    private func render() {
        updateLoginState()
        let expired = quota?.reset.map { $0 <= Date() } ?? false
        let stale = errorMessage != nil || expired || (updated.map { Date().timeIntervalSince($0) > 150 } ?? true)
        if let q = quota {
            item.button?.title = "Codex \(q.remaining)%" + (stale ? " !" : "")
            primaryLine.title = "5 часов: осталось \(q.remaining)%" + (stale ? " · устарело" : "")
            resetLine.title = q.reset.map { "Сброс: \(format($0))" } ?? "Время сброса неизвестно"
        } else {
            item.button?.title = "Codex —"
            primaryLine.title = "Пятичасовой лимит пока неизвестен"
            resetLine.title = ""
        }
        resetLine.isHidden = resetLine.title.isEmpty
        weeklyLine.title = weekly.map { "Неделя: осталось \($0.remaining)%" } ?? "Недельный лимит недоступен"
        updateLine.title = updated.map { "Обновлено: \(format($0)) · каждые 60 с" } ?? "Обновление каждую минуту"
        errorLine.title = errorMessage ?? (expired ? "Ожидается обновление после сброса" : "")
        errorLine.isHidden = errorLine.title.isEmpty
        item.button?.toolTip = primaryLine.title + "\n" + resetLine.title + (stale ? "\nДанные могут быть устаревшими" : "")
    }
    @objc private func refreshNow() { client.refresh() }
    @objc private func wokeUp() { render(); client.refresh() }
    @objc private func quitApp() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { timer?.invalidate(); client.stop() }
}

if CommandLine.arguments.contains("--self-test") {
    func quota(_ raw: [String: Any]) -> WindowQuota? { WindowQuota(raw) }
    func check(_ condition: Bool, _ name: String) { if !condition { print("FAIL: " + name); exit(1) } }
    check(quota(["usedPercent": 0.0, "windowDurationMins": 300])?.remaining == 100, "unused")
    check(quota(["usedPercent": 100.0, "windowDurationMins": 300])?.remaining == 0, "exhausted")
    check(quota(["usedPercent": 71.0, "windowDurationMins": 300])?.remaining == 29, "remaining")
    check(quota(["usedPercent": 71.8, "windowDurationMins": 300])?.remaining == 28, "conservative rounding")
    check(quota(["windowDurationMins": 300]) == nil, "unknown is not zero")
    check(quota(["usedPercent": -1.0, "windowDurationMins": 300]) == nil, "invalid usage")
    check(quota(["usedPercent": 10.0]) == nil, "unknown duration")
    check(quota(["usedPercent": 105.0, "windowDurationMins": 300])?.remaining == 0, "over limit")
    print("PASS: 8 quota parsing checks")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
