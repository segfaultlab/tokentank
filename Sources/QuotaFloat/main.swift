import AppKit
import SwiftUI

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FloatingPanel!
    private var statusItem: NSStatusItem!
    private let model = Model()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = NSHostingController(rootView: ContentView(model: model) { [weak self] in
            self?.panel.orderOut(nil)
        })
        host.sizingOptions = .preferredContentSize

        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 270, height: 360),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.contentViewController = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent",
                                           accessibilityDescription: "AI 额度")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        model.start()
        showPanel()
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else if panel.isVisible {
            panel.orderOut(nil)
        } else {
            model.refreshQuota()
            showPanel()
        }
    }

    private func showPanel() {
        if let button = statusItem.button, let window = button.window {
            let icon = window.convertToScreen(button.convert(button.bounds, to: nil))
            let screen = window.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
            let width = panel.frame.width
            let x = min(max(icon.midX - width / 2, screen.minX + 8), screen.maxX - width - 8)
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: icon.minY - 6))
        }
        panel.orderFrontRegardless()
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
