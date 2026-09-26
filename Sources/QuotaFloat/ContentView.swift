import SwiftUI

enum Fmt {
    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M/d HH:mm"
        return f.string(from: date)
    }
}

struct ContentView: View {
    @ObservedObject var model: Model
    var onHide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            QuotaSection(name: "Claude", load: model.claude)
            QuotaSection(name: "Codex", load: model.codex)
            QuotaSection(name: "Grok", load: model.grok)
            Divider()
            versions
        }
        .padding(14)
        .frame(width: 270)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("AI 额度").font(.system(size: 13, weight: .bold))
            if let t = model.updatedAt {
                Text("\(Fmt.time(t)) 更新").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.refreshAll() } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(model.refreshing ? 360 : 0))
                    .animation(model.refreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                               value: model.refreshing)
            }
            .help("刷新额度和版本")
            Button(action: onHide) { Image(systemName: "xmark") }
                .help("收起（点菜单栏图标再打开）")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
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
        !model.upgrading && !model.checkingVersions && model.outdatedCount > 0
    }

    private var upgradeTitle: String {
        if model.upgrading { return "升级中…" }
        if model.checkingVersions { return "检查版本中…" }
        return model.outdatedCount > 0 ? "一键升级（\(model.outdatedCount) 个）" : "都是最新版"
    }
}

struct QuotaSection: View {
    let name: String
    let load: Load

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(name).font(.system(size: 12, weight: .semibold))
                if case .loaded(let q) = load, let plan = q.plan {
                    Text(plan).font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
            switch load {
            case .loading:
                ProgressView().controlSize(.small)
            case .failed(let msg):
                Text(msg).font(.system(size: 11)).foregroundStyle(.red).lineLimit(2)
            case .loaded(let q):
                ForEach(q.windows) { WindowRow(window: $0) }
            }
        }
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
                Text("已用 \(Int(window.usedPercent.rounded()))%").monospacedDigit()
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
        guard let current = tool.current else { return tool.latest == nil ? "…" : "未安装" }
        return tool.outdated ? "\(current) → \(tool.latest!)" : current
    }

    @ViewBuilder private var status: some View {
        switch tool.state {
        case .updating:
            ProgressView().controlSize(.mini)
        case .failed(let msg):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help(msg)
        default:
            if tool.outdated {
                Image(systemName: "arrow.up.circle.fill").foregroundStyle(.orange).help("有新版本")
            } else if tool.current != nil {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("已是最新")
            }
        }
    }
}
