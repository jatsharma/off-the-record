import AppKit
import SwiftUI
import GRDB
import ScreenCaptureKit

/// Developer hook: `NotesApp --screenshots <dir>` renders the main window in a few
/// states and the Settings window to PNG files, using the app's own view cache so no
/// screen-recording permission is needed. Used to review the UI from a script.
enum Screenshots {
    static var directory: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--screenshots"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }

    @MainActor
    static func run(select: @escaping (String?) -> Void, openSettings: @escaping () -> Void) async {
        guard let dir = directory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(1.5))
        select(nil)
        try? await Task.sleep(for: .seconds(0.8))
        await capture(mainWindow(), to: dir.appendingPathComponent("1-record.png"))
        if let latest = latestMeeting() {
            select(latest.id)
            try? await Task.sleep(for: .seconds(1.2))
            await capture(mainWindow(), to: dir.appendingPathComponent("2-meeting.png"))
        }
        openSettings()
        try? await Task.sleep(for: .seconds(1.5))
        try? await Task.sleep(for: .seconds(1.5))
        if let settings = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("Settings_window") == true }) {
            // Walk the settings tabs so each page is captured.
            let toolbarItems = settings.toolbar?.items ?? []
            if toolbarItems.isEmpty {
                await capture(settings, to: dir.appendingPathComponent("3-settings.png"))
            } else {
                for (i, item) in toolbarItems.enumerated() {
                    _ = item.target?.perform(item.action, with: item)
                    try? await Task.sleep(for: .seconds(1.2))
                    await capture(settings, to: dir.appendingPathComponent("3-settings-\(i + 1).png"))
                }
            }
        }
        NSLog("Screenshots written to \(dir.path)")
        NSApp.terminate(nil)
    }

    private static func latestMeeting() -> Meeting? {
        try? AppDatabase.shared.pool.read { try Meeting.order(Column("createdAt").desc).fetchOne($0) }
    }

    @MainActor
    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.contentView != nil && !($0.title.localizedCaseInsensitiveContains("settings")) }
    }

    /// Captures the window through ScreenCaptureKit (the app already holds the
    /// Screen & System Audio Recording permission for its audio capture).
    @MainActor
    private static func capture(_ window: NSWindow?, to url: URL) async {
        guard let window else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                NSLog("Screenshots: window \(window.windowNumber) not in shareable content"); return
            }
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = SCStreamConfiguration()
            let scale = window.backingScaleFactor
            config.width = Int(scWindow.frame.width * scale)
            config.height = Int(scWindow.frame.height * scale)
            config.showsCursor = false
            config.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let rep = NSBitmapImageRep(cgImage: image)
            guard let data = rep.representation(using: .png, properties: [:]) else { return }
            try data.write(to: url)
        } catch {
            NSLog("Screenshots: capture failed: \(error.localizedDescription)")
        }
    }
}
