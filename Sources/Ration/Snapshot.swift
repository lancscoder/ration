import AppKit
import RationCore
import SwiftUI

/// Debug aid: `Ration --snapshot <dir>` renders the menu bar label (light
/// and dark) and the panel to PNGs using cached data, then exits. Makes UI
/// checks possible without screen-recording permission.
@MainActor
enum Snapshot {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let state = AppState()
        Task { @MainActor in
            await state.loadForSnapshot()
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let image = MenuBarLabelRenderer.image(for: state.menuBarModel)
                write(image: image, appearance: NSAppearance(named: appearance)!, background: appearance == .aqua ? .white : .black,
                      to: dir.appendingPathComponent("label-\(name).png"))
                let panel = PanelView(state: state, snapshotMode: true)
                    .environment(\.colorScheme, appearance == .aqua ? .light : .dark)
                    .background(appearance == .aqua ? Color.white : Color(white: 0.15))
                let renderer = ImageRenderer(content: panel)
                renderer.scale = 2
                if let cg = renderer.cgImage {
                    let rep = NSBitmapImageRep(cgImage: cg)
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("panel-\(name).png"))
                }
            }
            // Forms are AppKit-backed, which ImageRenderer can't draw: use a real offscreen window.
            state.showingSettings = true
            let host = NSHostingView(rootView: PanelView(state: state, snapshotMode: true))
            let window = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 400, height: 620), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            window.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(600))
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("settings-light.png"))
            }
            window.orderOut(nil)
            print("snapshots written to \(dir.path)")
            exit(0)
        }
    }

    private static func write(image: NSImage, appearance: NSAppearance, background: NSColor, to url: URL) {
        let scale: CGFloat = 4
        let size = NSSize(width: image.size.width + 8, height: image.size.height + 4)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance.performAsCurrentDrawingAppearance {
            background.setFill()
            NSRect(origin: .zero, size: size).fill()
            image.draw(in: NSRect(x: 4, y: 2, width: image.size.width, height: image.size.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
