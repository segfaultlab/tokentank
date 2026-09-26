import AppKit

enum Load {
    case loading
    case loaded(Quota)
    case failed(String)
}

@MainActor
final class Model: ObservableObject {
    @Published var claude: Load = .loading
    @Published var codex: Load = .loading
    @Published var grok: Load = .loading
    @Published var tools = Tool.all
    @Published var updatedAt: Date?
    @Published var refreshing = false
    @Published var checkingVersions = false
    @Published var upgrading = false
    @Published var selfLatest: String?
    @Published var selfUpdating = false
    @Published var selfUpdateError: String?
    let selfVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    private var timers: [Timer] = []

    var outdatedCount: Int { tools.filter(\.outdated).count }

    var selfOutdated: Bool {
        guard let selfLatest, let selfVersion else { return false }
        return selfLatest.compare(selfVersion, options: .numeric) == .orderedDescending
    }

    func start() {
        refreshAll()
        timers = [
            Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshQuota() }
            },
            Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.checkVersions() }
            },
        ]
    }

    func refreshAll() {
        refreshQuota()
        Task { await checkVersions() }
    }

    func refreshQuotaIfStale() {
        if let updatedAt, Date().timeIntervalSince(updatedAt) < 120 { return }
        refreshQuota()
    }

    func refreshQuota() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            async let a = Self.load { try await ClaudeQuota.fetch() }
            async let c = Self.load { try await CodexQuota.fetch() }
            async let g = Self.load { try await GrokQuota.fetch() }
            claude = Self.keepLastGood(claude, await a)
            codex = Self.keepLastGood(codex, await c)
            grok = Self.keepLastGood(grok, await g)
            updatedAt = Date()
            refreshing = false
        }
    }

    private static func keepLastGood(_ old: Load, _ new: Load) -> Load {
        guard case .failed(let message) = new, case .loaded(var quota) = old else { return new }
        quota.note = "\(message)，显示的是 \(Fmt.time(quota.fetchedAt)) 的数据"
        return .loaded(quota)
    }

    nonisolated private static func load(_ fetch: () async throws -> Quota) async -> Load {
        do { return .loaded(try await fetch()) } catch { return .failed(error.localizedDescription) }
    }

    func checkVersions() async {
        checkingVersions = true
        async let selfLatestCheck = Shell.run("npm view tokentank version")
        await withTaskGroup(of: (String, String?, String?).self) { group in
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
            }
        }
        let result = await selfLatestCheck
        if result.status == 0 {
            selfLatest = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        checkingVersions = false
    }

    func selfUpdate() {
        guard !selfUpdating else { return }
        selfUpdating = true
        selfUpdateError = nil
        Task {
            let result = await Shell.run("npm install -g tokentank@latest")
            guard result.status == 0 else {
                let tail = result.output.split(separator: "\n").suffix(3).joined(separator: "\n")
                selfUpdateError = tail.isEmpty ? "退出码 \(result.status)" : tail
                selfUpdating = false
                return
            }
            let pid = ProcessInfo.processInfo.processIdentifier
            let relaunch = Shell.process(
                "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open \"$(npm root -g)/tokentank/app/TokenTank.app\"")
            try? relaunch.run()
            NSApp.terminate(nil)
        }
    }

    func upgradeAll() {
        guard !upgrading else { return }
        upgrading = true
        Task {
            for i in tools.indices where tools[i].outdated {
                tools[i].state = .updating
                let result = await Shell.run(tools[i].upgradeCommand)
                if result.status == 0 {
                    tools[i].state = .done
                } else {
                    let tail = result.output.split(separator: "\n").suffix(3).joined(separator: "\n")
                    tools[i].state = .failed(tail.isEmpty ? "退出码 \(result.status)" : tail)
                }
            }
            await checkVersions()
            upgrading = false
        }
    }
}
