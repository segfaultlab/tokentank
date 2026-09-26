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

    static func run(_ command: String) async -> (status: Int32, output: String) {
        await Task.detached {
            let p = process(command)
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return (-1, error.localizedDescription) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }
}

func parseISODate(_ string: String?) -> Date? {
    guard var s = string else { return nil }
    if let r = s.range(of: #"\.\d+"#, options: .regularExpression) { s.removeSubrange(r) }
    return ISO8601DateFormatter().date(from: s)
}

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
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: killer)
        defer {
            killer.cancel()
            try? input.fileHandleForWriting.close()
            if p.isRunning { p.terminate() }
        }

        let messages = [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"tokentank","version":"1.0"}}}"#,
            #"{"method":"initialized"}"#,
            #"{"id":2,"method":"account/rateLimits/read"}"#,
        ]
        input.fileHandleForWriting.write(Data((messages.joined(separator: "\n") + "\n").utf8))

        var buffer = Data()
        let reader = output.fileHandleForReading
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { throw FetchError("codex 没有返回额度，确认已登录") }
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
                  let used = (w["usedPercent"] as? NSNumber)?.doubleValue else { return nil }
            let mins = (w["windowDurationMins"] as? NSNumber)?.intValue ?? 0
            let resets = (w["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return QuotaWindow(label: windowLabel(mins), usedPercent: used, resetsAt: resets)
        }
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
        let used = (rawUsed as? NSNumber)?.doubleValue ?? Double(rawUsed as? String ?? "") ?? 0
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
        let result = await Shell.run("security find-generic-password -s 'Claude Code-credentials' -w")
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

    private static var savedQuota: Quota? {
        get { defaults.data(forKey: "claude.lastQuota").flatMap { try? JSONDecoder().decode(Quota.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "claude.lastQuota") }
    }

    private static var nextRequestAt: Date {
        get { defaults.object(forKey: "claude.nextRequestAt") as? Date ?? .distantPast }
        set { defaults.set(newValue, forKey: "claude.nextRequestAt") }
    }

    private static func waitOrSaved() throws -> Quota {
        if let savedQuota { return savedQuota }
        throw FetchError("暂无数据，稍后自动获取", quiet: true)
    }

    static func fetch() async throws -> Quota {
        guard Date() >= nextRequestAt else { return try waitOrSaved() }
        nextRequestAt = Date().addingTimeInterval(300)
        let creds = try await loadCredentials()
        guard creds.expires > Date() else {
            cached = nil
            throw FetchError("Claude 登录已过期，打开一次 claude 会自动刷新")
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { cached = nil }
        if code == 429 {
            let wait = ((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init) ?? 0
            nextRequestAt = Date().addingTimeInterval(max(wait, 600))
            return try waitOrSaved()
        }
        guard code == 200 else { throw FetchError("Claude 返回 HTTP \(code)") }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError("Claude 返回格式看不懂")
        }

        let keys = [("five_hour", "5 小时"), ("seven_day", "本周"),
                    ("seven_day_opus", "本周 · Opus"), ("seven_day_sonnet", "本周 · Sonnet")]
        let windows = keys.compactMap { key, label -> QuotaWindow? in
            guard let w = obj[key] as? [String: Any],
                  let used = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return QuotaWindow(label: label, usedPercent: used, resetsAt: parseISODate(w["resets_at"] as? String))
        }
        let quota = Quota(plan: creds.plan, windows: windows)
        savedQuota = quota
        return quota
    }
}

enum UpdateState: Equatable {
    case idle, updating, done, failed(String)
}

struct Tool: Identifiable {
    let id: String
    let currentCommand: String
    let latestCommand: String
    let upgradeCommand: String
    var current: String?
    var latest: String?
    var state: UpdateState = .idle

    var outdated: Bool {
        guard let current, let latest else { return false }
        return current != latest
    }

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
             currentCommand: "grok update --check --json",
             latestCommand: "grok update --check --json",
             upgradeCommand: "grok update"),
    ]
}

enum Versions {
    static func check(_ tool: Tool) async -> (current: String?, latest: String?) {
        if tool.id == "grok" {
            let out = await Shell.run(tool.currentCommand).output
            guard let line = out.split(separator: "\n").last(where: { $0.hasPrefix("{") }),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { return (nil, nil) }
            return (obj["currentVersion"] as? String, obj["latestVersion"] as? String)
        }
        async let cur = Shell.run(tool.currentCommand)
        async let lat = Shell.run(tool.latestCommand)
        return (lastVersion(in: await cur), lastVersion(in: await lat))
    }

    private static func lastVersion(in result: (status: Int32, output: String)) -> String? {
        guard result.status == 0 else { return nil }
        let matches = result.output.matches(of: #/\d+\.\d+\.\d+[\w.\-]*/#)
        return matches.last.map { String($0.output) }
    }
}
