import AppKit
import ClaudeBarCore
import SwiftUI

extension SessionState {
    var color: Color {
        switch self {
        case .busy: return .green
        case .waiting: return .blue
        case .idle: return .secondary.opacity(0.4)
        }
    }
    var label: String {
        switch self {
        case .busy: return "Working"
        case .waiting: return "Waiting for you"
        case .idle: return "Not running"
        }
    }
}

struct SessionsSection: View {
    let state: AppState
    @State private var confirmingKill: String?

    var body: some View {
        CollapsibleCard(section: .sessions, prefs: state.prefs, trailing: AnyView(summary), collapsedSummary: AnyView(summary)) {
            if let error = state.sessionActionError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let notice = state.sessionActionNotice {
                Label(notice, systemImage: "doc.on.clipboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !state.logsLoaded && state.sessions.isEmpty {
                Text("Looking for sessions…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                let running = state.sessions.filter(\.isLive)
                let ended = state.sessions.filter { !$0.isLive }
                VStack(alignment: .leading, spacing: 2) {
                    if running.isEmpty {
                        Text("No sessions running.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                    }
                    ForEach(running) { row($0) }
                    Text("Ended in the last \(state.prefs.endedSessionWindowText)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .padding(.horizontal, 6)
                        .padding(.top, 8)
                    if ended.isEmpty {
                        Text("None. Resume appears here once a session ends.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                    }
                    ForEach(ended) { row($0) }
                }
            }
        }
    }

    private func row(_ session: SessionInfo) -> some View {
        SessionRow(session: session, now: state.now, confirmingKill: $confirmingKill,
                   onResume: { state.resume(session) },
                   onKill: { state.kill(session) })
    }

    private var summary: some View {
        let busy = state.sessions.filter { $0.state == .busy }.count
        let waiting = state.sessions.filter { $0.state == .waiting }.count
        return HStack(spacing: 8) {
            if busy > 0 { Label("\(busy)", systemImage: "circle.fill").foregroundStyle(.green) }
            if waiting > 0 { Label("\(waiting)", systemImage: "circle.fill").foregroundStyle(.blue) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(busy) working, \(waiting) waiting")
        .labelStyle(DotLabelStyle())
        .font(.caption.monospacedDigit())
    }
}

private struct DotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 6))
            configuration.title.foregroundStyle(.secondary)
        }
    }
}

struct SessionRow: View {
    let session: SessionInfo
    let now: Date
    @Binding var confirmingKill: String?
    let onResume: () -> Void
    let onKill: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.needsPermission ? Color.orange : session.state.color)
                .frame(width: 8, height: 8)
                .help(stateLabel)
                .accessibilityLabel(stateLabel)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(session.projectName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if let name = session.name, !name.isEmpty {
                        Text(name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if confirmingKill != session.sessionId {
                Menu {
                    actions
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .opacity(hovering ? 1 : 0.5)
                .help("More actions")
                .accessibilityLabel("More actions for \(session.projectName)")
            }
            if confirmingKill == session.sessionId {
                Button("Cancel") { confirmingKill = nil }
                    .controlSize(.small)
                Button("Stop it", role: .destructive) {
                    confirmingKill = nil
                    onKill()
                }
                .controlSize(.small)
                .tint(.red)
            } else {
                if !session.isLive {
                    Button(action: onResume) {
                        Label("Resume", systemImage: "arrow.uturn.forward")
                    }
                    .controlSize(.small)
                    .help("Continue this conversation: claude --resume in its project folder")
                } else {
                    Button {
                        confirmingKill = session.sessionId
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .controlSize(.small)
                    .opacity(hovering ? 1 : 0.6)
                    .help("Stop this Claude process (SIGTERM)")
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .onHover { hovering = $0 }
        .help(session.cwd ?? "")
        .contextMenu { actions }
    }

    @ViewBuilder private var actions: some View {
        if session.isLive {
            Button("Stop…") { confirmingKill = session.sessionId }
        } else {
            Button("Resume") { onResume() }
        }
        Divider()
        if let cwd = session.cwd {
            Button("Show Folder in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd, isDirectory: true)])
            }
            .disabled(!FileManager.default.fileExists(atPath: cwd))
            Button("Copy Folder Path") { copy(cwd) }
            if let command = TerminalCatalog.pasteCommand(cwd: cwd, sessionId: session.sessionId) {
                Button("Copy Resume Command") { copy(command) }
            }
        }
        Button("Copy Session ID") { copy(session.sessionId) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var stateLabel: String {
        session.needsPermission ? "Needs your permission" : session.state.label
    }

    private var detail: String {
        var parts: [String] = []
        if let model = session.model { parts.append(ModelName.display(model)) }
        switch session.state {
        case .busy:
            parts.append(session.state.label)
        case .waiting:
            let label = session.needsPermission ? "Needs permission" : "Waiting"
            parts.append(session.lastActivity.map { "\(label) · \(Fmt.ago($0, now: now))" } ?? label)
        case .idle:
            if let last = session.lastActivity { parts.append(Fmt.ago(last, now: now)) }
        }
        if let tokens = session.tokens {
            parts.append("\(Fmt.tokens(tokens.total(includingCacheReads: false))) tok")
        }
        return parts.joined(separator: " · ")
    }
}
