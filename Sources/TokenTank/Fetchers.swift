import Foundation

struct FetchError: LocalizedError {
    let message: String
    var quiet = false
    init(_ message: String, quiet: Bool = false) {
        self.message = message
        self.quiet = quiet
    }
    var errorDescription: String? { message }
}

struct QuotaWindow: Identifiable, Codable {
    var id = UUID()
    let label: String
    let usedPercent: Double
    let resetsAt: Date?

    enum CodingKeys: String, CodingKey { case label, usedPercent, resetsAt }
}

struct Quota: Codable {
    var plan: String?
    var windows: [QuotaWindow]
    var note: String?
    var fetchedAt = Date()

    enum CodingKeys: String, CodingKey { case plan, windows, fetchedAt }
}

enum Shell {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    static func process(_ command: String) -> Process {
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.grok/bin", "\(home)/.local/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        p.environment = env
        return p
    }

    static func run(_ command: String, timeout: TimeInterval = 60) async -> (status: Int32, output: String) {
        await withCheckedContinuation { cont in
            let p = process(command)
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            let buffer = OutputBuffer()
            let eof = DispatchSemaphore(value: 0)
            pipe.fileHandleForReading.readabilityHandler = { h in
                if buffer.read(h) {
                    h.readabilityHandler = nil
                    eof.signal()
                }
            }
            let cleaned = DispatchSemaphore(value: 0)
            p.terminationHandler = { p in
                buffer.markExited()
                _ = eof.wait(timeout: .now() + 1)
                pipe.fileHandleForReading.readabilityHandler = nil
                let (output, timedOut) = buffer.finish(draining: pipe.fileHandleForReading)
                if timedOut {
                    _ = cleaned.wait(timeout: .now() + 10)
                    cont.resume(returning: (-1, "命令超过 \(Int(timeout)) 秒没有结束，已终止"))
                } else {
                    cont.resume(returning: (p.terminationStatus, output))
                }
            }
            do {
                try p.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: (-1, error.localizedDescription))
                return
            }
            let pgid = p.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard buffer.markTimedOut() else { return }
                terminateGroup(pgid)
                cleaned.signal()
            }
        }
    }

    static func terminateGroup(_ pgid: pid_t) {
        guard kill(-pgid, SIGTERM) == 0 else { return }
        for _ in 0..<30 {
            usleep(100_000)
            if kill(-pgid, 0) != 0 { return }
        }
        kill(-pgid, SIGKILL)
    }
}

final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var exited = false
    private var finished = false
    private var didTimeOut = false

    var timedOut: Bool { lock.withLock { didTimeOut } }

    func read(_ h: FileHandle) -> Bool {
        lock.withLock {
            let chunk = h.availableData
            if !finished { data.append(chunk) }
            return chunk.isEmpty
        }
    }

    func markExited() { lock.withLock { exited = true } }

    func markTimedOut() -> Bool {
        lock.withLock {
            if !exited { didTimeOut = true }
            return didTimeOut
        }
    }

    func finish(draining h: FileHandle) -> (String, Bool) {
        lock.withLock {
            let fd = h.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = Darwin.read(fd, &chunk, chunk.count)
                if n <= 0 { break }
                data.append(contentsOf: chunk[0..<n])
            }
            finished = true
            return (String(decoding: data, as: UTF8.self), didTimeOut)
        }
    }
}

func parseISODate(_ string: String?) -> Date? {
    guard var s = string else { return nil }
    if let r = s.range(of: #"\.\d+"#, options: .regularExpression) { s.removeSubrange(r) }
    return ISO8601DateFormatter().date(from: s)
}

private let httpDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "GMT")
    f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return f
}()

enum CodexQuota {
    static func fetch() async throws -> Quota {
        try await Task.detached { try fetchSync() }.value
    }

    private static func fetchSync() throws -> Quota {
        let p = Shell.process("exec codex app-server")
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        try p.run()
        let pgid = p.processIdentifier
        let state = OutputBuffer()
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
            if state.markTimedOut() { Shell.terminateGroup(pgid) }
        }
        defer {
            state.markExited()
            try? input.fileHandleForWriting.close()
            DispatchQueue.global().async { Shell.terminateGroup(pgid) }
        }

        let messages = [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"tokentank","version":"1.0"}}}"#,
            #"{"method":"initialized"}"#,
            #"{"id":2,"method":"account/rateLimits/read"}"#,
        ]
        try input.fileHandleForWriting.write(contentsOf: Data((messages.joined(separator: "\n") + "\n").utf8))

        var buffer = Data()
        let reader = output.fileHandleForReading
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty {
                throw FetchError(state.timedOut ? "codex 30 秒内没有返回额度" : "codex 没有返回额度，确认已登录")
            }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      obj["id"] as? Int == 2 else { continue }
                if let err = obj["error"] as? [String: Any] {
                    throw FetchError(err["message"] as? String ?? "codex 返回错误")
                }
                return try parse(obj["result"] as? [String: Any])
            }
        }
    }

    private static func parse(_ result: [String: Any]?) throws -> Quota {
        guard let limits = result?["rateLimits"] as? [String: Any] else {
            throw FetchError("codex 返回里没有额度信息")
        }
        let windows = ["primary", "secondary"].compactMap { key -> QuotaWindow? in
            guard let w = limits[key] as? [String: Any],
                  let used = (w["usedPercent"] as? NSNumber)?.doubleValue, used.isFinite else { return nil }
            let mins = (w["windowDurationMins"] as? NSNumber)?.intValue ?? 0
            let resets = (w["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return QuotaWindow(label: windowLabel(mins), usedPercent: used, resetsAt: resets)
        }
        guard !windows.isEmpty else { throw FetchError("codex 返回里没有额度信息") }
        return Quota(plan: (limits["planType"] as? String)?.capitalized, windows: windows)
    }

    private static func windowLabel(_ mins: Int) -> String {
        if mins == 10080 { return "本周" }
        if mins > 0 && mins % 1440 == 0 { return "\(mins / 1440) 天" }
        if mins > 0 && mins % 60 == 0 { return "\(mins / 60) 小时" }
        return "\(mins) 分钟"
    }
}

enum GrokQuota {
    private static let authPath = Shell.home + "/.grok/auth.json"

    private static func loadAuth() -> (key: String, expires: Date)? {
        guard let data = FileManager.default.contents(atPath: authPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = obj.values.compactMap({ $0 as? [String: Any] }).first,
              let key = entry["key"] as? String else { return nil }
        return (key, parseISODate(entry["expires_at"] as? String) ?? .distantPast)
    }

    static func fetch() async throws -> Quota {
        var auth = loadAuth()
        if auth == nil || auth!.expires < Date().addingTimeInterval(120) {
            _ = await Shell.run("grok models")
            auth = loadAuth()
        }
        guard let auth else { throw FetchError("没有 Grok 登录信息，先在终端运行 grok login") }

        var req = URLRequest(url: URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!)
        req.setValue("Bearer \(auth.key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw FetchError("Grok 返回 HTTP \(code)") }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = obj["config"] as? [String: Any] else {
            throw FetchError("Grok 返回格式看不懂")
        }

        let rawUsed = config["creditUsagePercent"]
        guard let used = (rawUsed as? NSNumber)?.doubleValue ?? Double(rawUsed as? String ?? ""), used.isFinite else {
            throw FetchError("Grok 返回里没有用量百分比")
        }
        let period = config["currentPeriod"] as? [String: Any]
        let label = (period?["type"] as? String)?.contains("MONTH") == true ? "本月" : "本周"
        let end = parseISODate(period?["end"] as? String ?? config["billingPeriodEnd"] as? String)
        return Quota(plan: nil, windows: [QuotaWindow(label: label, usedPercent: used, resetsAt: end)])
    }
}

enum ClaudeQuota {
    private static var cached: (token: String, plan: String?, expires: Date)?

    private static func loadCredentials() async throws -> (token: String, plan: String?, expires: Date) {
        if let cached, cached.expires > Date().addingTimeInterval(60) { return cached }
        let result = await Shell.run("security find-generic-password -s 'Claude Code-credentials' -w", timeout: 300)
        guard result.status == 0,
              let obj = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            throw FetchError("读不到 Claude 登录信息（钥匙串未授权或未登录）")
        }
        let expiresMs = (oauth["expiresAt"] as? NSNumber)?.doubleValue ?? 0
        let creds = (token, (oauth["subscriptionType"] as? String)?.capitalized,
                     Date(timeIntervalSince1970: expiresMs / 1000))
        cached = creds
        return creds
    }

    private static let defaults = UserDefaults.standard

    static var savedQuota: Quota? {
        get { defaults.data(forKey: "claude.lastQuota").flatMap { try? JSONDecoder().decode(Quota.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "claude.lastQuota") }
    }

    static var nextRequestAt: Date {
        get { defaults.object(forKey: "claude.nextRequestAt") as? Date ?? .distantPast }
        set { defaults.set(newValue, forKey: "claude.nextRequestAt") }
    }

    private static func retryAfter(_ resp: URLResponse) -> Date? {
        guard let value = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = Double(value) { return Date().addingTimeInterval(seconds) }
        return httpDateFormatter.date(from: value)
    }

    private static var lastRenewAt = Date.distantPast

    private static func renewViaCLI() async {
        guard Date().timeIntervalSince(lastRenewAt) >= 300 else { return }
        lastRenewAt = Date()
        _ = await Shell.run("claude -p --no-session-persistence /cost", timeout: 60)
    }

    static func fetch() async throws -> Quota {
        var creds = try await loadCredentials()
        if creds.expires <= Date() {
            await renewViaCLI()
            creds = try await loadCredentials()
        }
        guard creds.expires > Date() else {
            cached = nil
            throw FetchError("Claude 登录已过期，打开一次 claude 会自动刷新")
        }
        guard Date() >= nextRequestAt else {
            throw FetchError("暂无数据，\(Fmt.time(nextRequestAt)) 后自动获取", quiet: true)
        }
        nextRequestAt = Date().addingTimeInterval(300)
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { cached = nil }
        if code == 429 {
            nextRequestAt = max(Date().addingTimeInterval(600), retryAfter(resp) ?? .distantPast)
            throw FetchError("暂无数据，\(Fmt.time(nextRequestAt)) 后自动获取", quiet: true)
        }
        guard code == 200 else { throw FetchError("Claude 返回 HTTP \(code)") }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError("Claude 返回格式看不懂")
        }

        let keys = [("five_hour", "5 小时"), ("seven_day", "本周"),
                    ("seven_day_opus", "本周 · Opus"), ("seven_day_sonnet", "本周 · Sonnet")]
        let windows = keys.compactMap { key, label -> QuotaWindow? in
            guard let w = obj[key] as? [String: Any],
                  let used = (w["utilization"] as? NSNumber)?.doubleValue, used.isFinite else { return nil }
            return QuotaWindow(label: label, usedPercent: used, resetsAt: parseISODate(w["resets_at"] as? String))
        }
        guard !windows.isEmpty else { throw FetchError("Claude 返回里没有额度信息") }
        let quota = Quota(plan: creds.plan, windows: windows)
        savedQuota = quota
        return quota
    }
}

enum UpdateState: Equatable {
    case idle, queued, updating, failed(String)
}

enum Probe: Equatable {
    case unknown, missing, version(String)

    var version: String? {
        if case .version(let v) = self { return v }
        return nil
    }
}

func isNewer(_ a: String, than b: String) -> Bool {
    a.compare(b, options: .numeric) == .orderedDescending
}

struct Tool: Identifiable {
    let id: String
    let currentCommand: String
    let latestCommand: String
    let upgradeCommand: String
    var current: Probe = .unknown
    var latest: Probe = .unknown
    var checked = false
    var state: UpdateState = .idle

    var outdated: Bool {
        guard let c = current.version, let l = latest.version else { return false }
        return isNewer(l, than: c)
    }

    var upToDate: Bool { current.version != nil && latest.version != nil && !outdated }
    var unknown: Bool { checked && current != .missing && !upToDate && !outdated }

    static let all = [
        Tool(id: "claude",
             currentCommand: "claude --version",
             latestCommand: "npm view @anthropic-ai/claude-code version",
             upgradeCommand: "claude update"),
        Tool(id: "codex",
             currentCommand: "codex --version",
             latestCommand: "npm view @openai/codex version",
             upgradeCommand: "npm install -g @openai/codex@latest"),
        Tool(id: "grok",
             currentCommand: "grok --version",
             latestCommand: "grok update --check --json",
             upgradeCommand: "grok update"),
    ]
}

enum Versions {
    static func check(_ tool: Tool) async -> (current: Probe, latest: Probe) {
        async let cur = current(tool)
        async let lat = latest(tool)
        return await (cur, lat)
    }

    static func current(_ tool: Tool) async -> Probe {
        let result = await Shell.run(tool.currentCommand)
        if result.status == 127 {
            return await Shell.run("command -v \(tool.id)").status == 0 ? .unknown : .missing
        }
        return lastVersion(in: result)
    }

    private static func latest(_ tool: Tool) async -> Probe {
        let result = await Shell.run(tool.latestCommand)
        guard tool.id == "grok" else { return lastVersion(in: result) }
        guard result.status == 0,
              let line = result.output.split(separator: "\n").last(where: { $0.hasPrefix("{") }),
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let v = obj["latestVersion"] as? String else { return .unknown }
        return .version(v)
    }

    private static func lastVersion(in result: (status: Int32, output: String)) -> Probe {
        guard result.status == 0,
              let m = result.output.matches(of: #/\d+\.\d+\.\d+[\w.\-]*/#).last else { return .unknown }
        return .version(String(m.output))
    }
}
