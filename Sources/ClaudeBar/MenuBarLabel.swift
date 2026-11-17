import AppKit
import ClaudeBarCore
import SwiftUI

/// What the menu bar item shows; equatable so SwiftUI only re-renders on change.
struct MenuBarLabelModel: Equatable {
    enum Dot: Equatable { case busy, waiting }
    var text: String
    var level: UsageLevel
    var dimmed: Bool
    var dot: Dot?
}

/// Renders the label into an `NSImage` whose drawing handler resolves colours
/// at draw time, so `labelColor` follows the menu bar's light/dark appearance
/// while the amber/red/dot colours stay coloured (a template image would lose them).
enum MenuBarLabelRenderer {
    static func image(for model: MenuBarLabelModel) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let symbol = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Claude usage")?
            .withSymbolConfiguration(symbolConfig)
        let symbolSize = symbol?.size ?? NSSize(width: 10, height: 14)

        let textSize = model.text.isEmpty ? .zero : (model.text as NSString).size(withAttributes: [.font: font])
        let dotDiameter: CGFloat = 6
        let gap: CGFloat = 3
        var width = ceil(symbolSize.width + (model.text.isEmpty ? 0 : gap + textSize.width))
        if model.dot != nil { width += gap + 1 + dotDiameter }
        let height: CGFloat = 18

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let base: NSColor = model.dimmed ? .secondaryLabelColor : .labelColor
            let tint: NSColor
            switch model.level {
            case .normal: tint = base
            case .warning: tint = .systemOrange
            case .critical: tint = .systemRed
            }

            var x: CGFloat = 0
            if let symbol {
                let tinted = symbol.withSymbolConfiguration(.init(paletteColors: [tint])) ?? symbol
                let y = (rect.height - symbolSize.height) / 2
                tinted.draw(in: NSRect(x: x, y: y, width: symbolSize.width, height: symbolSize.height))
                x += symbolSize.width + gap
            }

            if !model.text.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tint]
                let ty = (rect.height - textSize.height) / 2
                (model.text as NSString).draw(at: NSPoint(x: x, y: ty), withAttributes: attrs)
                x += textSize.width + gap + 1
            } else {
                x += 1
            }

            if let dot = model.dot {
                let color: NSColor = dot == .busy ? .systemGreen : .systemBlue
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: (rect.height - dotDiameter) / 2, width: dotDiameter, height: dotDiameter)).fill()
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Claude usage \(model.text)"
        return image
    }
}

struct MenuBarLabelView: View {
    let state: AppState

    var body: some View {
        Image(nsImage: MenuBarLabelRenderer.image(for: state.menuBarModel))
    }
}

extension AppState {
    var menuBarModel: MenuBarLabelModel {
        let dot = prefs.labelShowStatus ? sessionDot : nil
        guard let response = usage.response else {
            let text: String
            switch usage.status {
            case .loginStale, .noCredentials: text = "login"
            default: text = prefs.labelOptions.showsAnyText ? "–" : ""
            }
            return MenuBarLabelModel(text: text, level: .normal, dimmed: true, dot: dot)
        }
        let session = response.session
        let weekly = response.weekly
        let text = MenuBarText.compose(session: session, weekly: weekly, options: prefs.labelOptions, now: now)
        let levelSource: Double
        switch prefs.labelFormat {
        case .session: levelSource = session?.utilization ?? 0
        case .weekly: levelSource = weekly?.utilization ?? 0
        case .both: levelSource = max(session?.utilization ?? 0, weekly?.utilization ?? 0)
        }
        return MenuBarLabelModel(text: text, level: prefs.level(for: levelSource), dimmed: isUsageStale, dot: dot)
    }

    var sessionDot: MenuBarLabelModel.Dot? {
        switch sessionDotState {
        case .busy: return .busy
        case .waiting: return .waiting
        default: return nil
        }
    }
}
