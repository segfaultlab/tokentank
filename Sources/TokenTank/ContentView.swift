import SwiftUI

enum Fmt {
    private static let today = formatter("HH:mm")
    private static let other = formatter("M/d HH:mm")

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = format
        return f
    }

    static func time(_ date: Date) -> String {
        (Calendar.current.isDateInToday(date) ? today : other).string(from: date)
    }
}

struct ContentView: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ForEach(Provider.allCases) { p in
                QuotaSection(provider: p, load: model.quotas[p] ?? .loading, loading: model.inFlight.contains(p))
            }
            Divider()
            versions
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 270)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("TokenTank").font(.system(size: 13, weight: .bold))
            if model.selfOutdated || model.selfUpdating {
                selfUpdateBadge
            }
            Spacer()
            Button { model.refreshAll() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(HoverIconButtonStyle())
                .help("刷新额度和版本")
        }
        .frame(height: 22)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private var footer: some View {
        HStack {
            Text("TokenTank \(model.selfVersion ?? "")")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power").font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(HoverIconButtonStyle())
            .help("退出 TokenTank")
        }
    }

    private var selfUpdateBadge: some View {
        let failed = model.selfUpdateError != nil
        let title = model.selfUpdating ? "更新中…" : failed ? "升级失败" : "↑ \(model.selfLatest ?? "")"
        return Button { model.selfUpdate() } label: {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(failed ? Color.red : Color.accentColor, in: Capsule())
        }
        .disabled(model.selfUpdating || model.upgrading)
        .help(model.selfUpdateError ?? "TokenTank 有新版本，点击升级并重启")
    }

    private var versions: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.tools) { ToolRow(tool: $0) }
            Button {
                model.upgradeAll()
            } label: {
                Text(upgradeTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(canUpgrade ? .white : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(canUpgrade ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                                in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(!canUpgrade)
            .padding(.top, 2)
        }
    }

    private var canUpgrade: Bool {
        !model.upgrading && !model.selfUpdating && !model.checkingVersions && model.outdatedCount > 0
    }

    private var upgradeTitle: String {
        if model.upgrading {
            let name = model.tools.first { $0.state == .updating }?.id
            return name.map { "正在升级 \($0)…" } ?? "升级中…"
        }
        if model.checkingVersions { return "检查版本中…" }
        if model.outdatedCount > 0 { return "一键升级（\(model.outdatedCount) 个）" }
        return model.tools.contains(where: \.unknown) ? "部分版本查不到" : "都是最新版"
    }
}

struct HoverIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverIcon(configuration: configuration)
    }

    private struct HoverIcon: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(.primary.opacity(configuration.isPressed ? 0.16 : hovering ? 0.08 : 0)))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

struct QuotaSection: View {
    let provider: Provider
    let load: Load
    let loading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(provider.rawValue).font(.system(size: 12, weight: .semibold))
                if case .loaded(let q) = load, let plan = q.plan {
                    Text(plan).font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if loading {
                    ProgressView().controlSize(.mini).scaleEffect(0.8)
                }
                if case .loaded(let q) = load {
                    Text("数据于 \(Fmt.time(q.fetchedAt))")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .help(timeHelp)
                }
            }
            .frame(height: 16)
            switch load {
            case .loading:
                ProgressView().controlSize(.small)
            case .pending(let msg):
                Text(msg).font(.system(size: 11)).foregroundStyle(.secondary)
            case .failed(let msg):
                Text(msg).font(.system(size: 11)).foregroundStyle(.red).lineLimit(2).help(msg)
            case .loaded(let q):
                ForEach(q.windows) { WindowRow(window: $0) }
                if let note = q.note {
                    Text("刷新失败，显示的是旧数据").font(.system(size: 10)).foregroundStyle(.orange).help(note)
                }
            }
        }
    }

    private var timeHelp: String {
        guard provider == .claude else { return "每 5 分钟自动刷新" }
        let next = ClaudeQuota.nextRequestAt
        return next > Date() ? "Claude 用量接口限流严格，\(Fmt.time(next)) 后才会再次查询" : "每 5 分钟自动刷新"
    }
}

struct WindowRow: View {
    let window: QuotaWindow

    private var color: Color {
        window.usedPercent >= 85 ? .red : window.usedPercent >= 60 ? .orange : .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.label)
                Spacer()
                Text("已用 \(window.usedPercent, format: .number.precision(.fractionLength(0)))%").monospacedDigit()
            }
            .font(.system(size: 11))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color)
                        .frame(width: max(4, geo.size.width * min(max(window.usedPercent, 0), 100) / 100))
                }
            }
            .frame(height: 5)
            if let r = window.resetsAt {
                Text("\(Fmt.time(r)) 重置").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}

struct ToolRow: View {
    let tool: Tool

    var body: some View {
        HStack(spacing: 6) {
            Text(tool.id).font(.system(size: 11, weight: .medium)).frame(width: 46, alignment: .leading)
            Text(versionText).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            Spacer()
            status
        }
    }

    private var versionText: String {
        if !tool.checked { return "…" }
        switch tool.current {
        case .missing: return "未安装"
        case .unknown: return "查不到版本"
        case .version(let v): return tool.outdated ? "\(v) → \(tool.latest.version!)" : v
        }
    }

    @ViewBuilder private var status: some View {
        switch tool.state {
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary).help("等待升级")
        case .updating:
            ProgressView().controlSize(.mini)
        case .failed(let msg):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help(msg)
        default:
            if tool.outdated {
                Image(systemName: "arrow.up.circle.fill").foregroundStyle(.orange).help("有新版本")
            } else if tool.upToDate {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("已是最新")
            } else if tool.unknown {
                Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                    .help(tool.current == .unknown ? "读取本地版本失败" : "查不到最新版本")
            }
        }
    }
}
