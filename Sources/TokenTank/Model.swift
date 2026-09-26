import Foundation

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
    private var timer: Timer?

    var outdatedCount: Int { tools.filter(\.outdated).count }

    func start() {
        refreshAll()
        timer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshQuota() }
        }
    }

    func refreshAll() {
        refreshQuota()
        Task { await checkVersions() }
    }

    func refreshQuota() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            async let a = Self.load { try await ClaudeQuota.fetch() }
            async let c = Self.load { try await CodexQuota.fetch() }
            async let g = Self.load { try await GrokQuota.fetch() }
            claude = await a
            codex = await c
            grok = await g
            updatedAt = Date()
            refreshing = false
        }
    }

    nonisolated private static func load(_ fetch: () async throws -> Quota) async -> Load {
        do { return .loaded(try await fetch()) } catch { return .failed(error.localizedDescription) }
    }

    func checkVersions() async {
        checkingVersions = true
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
        checkingVersions = false
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
