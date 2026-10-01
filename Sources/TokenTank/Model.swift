import AppKit

enum Load {
    case loading
    case loaded(Quota)
    case pending(String)
    case failed(String)
}

enum Provider: String, CaseIterable, Identifiable {
    case claude = "Claude", codex = "Codex", grok = "Grok"
    var id: Self { self }

    func fetch() async throws -> Quota {
        switch self {
        case .claude: try await ClaudeQuota.fetch()
        case .codex: try await CodexQuota.fetch()
        case .grok: try await GrokQuota.fetch()
        }
    }
}

@MainActor
final class Model: ObservableObject {
    @Published var quotas: [Provider: Load] = [:]
    @Published var inFlight: Set<Provider> = []
    @Published var tools = Tool.all
    @Published var checkingVersions = false
    @Published var upgrading = false
    @Published var selfLatest: String?
    @Published var selfUpdating = false
    @Published var selfUpdateError: String?
    let selfVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    private var timers: [Timer] = []
    private var doneAt: [Provider: Date] = [:]
    private var failures: [Provider: Int] = [:]
    private var versionCheck: Task<Void, Never>?

    var outdatedCount: Int { tools.filter(\.outdated).count }

    var selfOutdated: Bool {
        guard let selfLatest, let selfVersion else { return false }
        return selfLatest.compare(selfVersion, options: .numeric) == .orderedDescending
    }

    func start() {
        if let saved = ClaudeQuota.savedQuota {
            quotas[.claude] = .loaded(saved)
        } else if Date() < ClaudeQuota.nextRequestAt {
            quotas[.claude] = .pending("暂无数据，\(Fmt.time(ClaudeQuota.nextRequestAt)) 后自动获取")
        }
        refreshQuota()
        Task { await checkVersions() }
        timers = [
            Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshQuota() }
            },
            Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.checkVersions() }
            },
        ]
    }

    func refreshAll() {
        refreshQuota(maxAge: 0)
        Task { await checkVersions() }
    }

    func refreshQuota(maxAge: TimeInterval? = nil) {
        for p in Provider.allCases where !inFlight.contains(p) && isDue(p, maxAge: maxAge) {
            inFlight.insert(p)
            Task {
                let new = await Self.load(p)
                switch new {
                case .loaded: failures[p] = 0
                case .failed: failures[p, default: 0] += 1
                default: break
                }
                quotas[p] = Self.keepLastGood(quotas[p] ?? .loading, new)
                doneAt[p] = Date()
                inFlight.remove(p)
            }
        }
    }

    private func isDue(_ p: Provider, maxAge: TimeInterval?) -> Bool {
        if p == .claude && Date() < ClaudeQuota.nextRequestAt { return false }
        guard maxAge != 0, let done = doneAt[p] else { return true }
        let n = failures[p, default: 0]
        let wait: TimeInterval = n > 0 ? min(60 * pow(2, Double(n - 1)), 300) : min(300, maxAge ?? 300)
        return Date().timeIntervalSince(done) >= wait
    }

    private static func keepLastGood(_ old: Load, _ new: Load) -> Load {
        guard case .loaded(var quota) = old else { return new }
        switch new {
        case .pending:
            return old
        case .failed(let message):
            quota.note = message
            return .loaded(quota)
        default:
            return new
        }
    }

    nonisolated private static func load(_ p: Provider) async -> Load {
        do {
            return .loaded(try await p.fetch())
        } catch let error as FetchError where error.quiet {
            return .pending(error.message)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func checkVersions() async {
        guard !upgrading else { return }
        if let versionCheck { return await versionCheck.value }
        checkingVersions = true
        let task = Task { await runVersionCheck() }
        versionCheck = task
        await task.value
        versionCheck = nil
    }

    private func runVersionCheck() async {
        async let selfLatestCheck = Shell.run("npm view tokentank version")
        await withTaskGroup(of: (String, Probe, Probe).self) { group in
            for tool in tools {
                group.addTask {
                    let v = await Versions.check(tool)
                    return (tool.id, v.current, v.latest)
                }
            }
            for await (id, current, latest) in group {
                guard let i = tools.firstIndex(where: { $0.id == id }) else { continue }
                tools[i].current = current
                tools[i].latest = latest
                tools[i].checked = true
                if case .failed = tools[i].state, tools[i].upToDate { tools[i].state = .idle }
            }
        }
        let result = await selfLatestCheck
        if result.status == 0 {
            selfLatest = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        checkingVersions = false
    }

    func selfUpdate() {
        guard !selfUpdating, !upgrading else { return }
        selfUpdating = true
        selfUpdateError = nil
        Task {
            let result = await Shell.run("npm install -g tokentank@latest", timeout: 600)
            guard result.status == 0 else {
                selfUpdateError = Self.tail(result)
                selfUpdating = false
                return
            }
            let root = await Shell.run("npm root -g").output.trimmingCharacters(in: .whitespacesAndNewlines)
            let app = root + "/tokentank/app/TokenTank.app"
            let pid = ProcessInfo.processInfo.processIdentifier
            let relaunch = Shell.process(
                "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open \"$TOKENTANK_APP\"")
            relaunch.environment?["TOKENTANK_APP"] = app
            do {
                guard FileManager.default.fileExists(atPath: app + "/Contents/MacOS/TokenTank") else {
                    throw FetchError("找不到 \(app)")
                }
                try relaunch.run()
            } catch {
                selfUpdateError = "已安装新版，但没能自动重启：\(error.localizedDescription)。请在终端运行 tokentank"
                selfUpdating = false
                return
            }
            NSApp.terminate(nil)
        }
    }

    func upgradeAll() {
        guard !upgrading, !selfUpdating, !checkingVersions else { return }
        upgrading = true
        let targets = tools.indices.compactMap { i in tools[i].outdated ? (i, tools[i].latest.version!) : nil }
        for (i, _) in targets { tools[i].state = .queued }
        Task {
            for (i, target) in targets {
                tools[i].state = .updating
                let result = await Shell.run(tools[i].upgradeCommand, timeout: 600)
                let current = await Versions.current(tools[i])
                tools[i].current = current
                if result.status != 0 {
                    tools[i].state = .failed(Self.tail(result))
                } else if let v = current.version {
                    tools[i].state = isNewer(target, than: v) ? .failed("升级命令已执行，但当前版本仍是 \(v)") : .idle
                } else {
                    tools[i].state = .failed("升级命令已执行，但无法确认升级后的版本")
                }
            }
            upgrading = false
        }
    }

    private static func tail(_ result: (status: Int32, output: String)) -> String {
        let tail = result.output.split(separator: "\n").suffix(3).joined(separator: "\n")
        return tail.isEmpty ? "退出码 \(result.status)" : tail
    }
}
