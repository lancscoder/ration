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
            if state.sessions.isEmpty {
                Text(state.logsLoaded ? "No sessions in the last 24 hours." : "Looking for sessions…")
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
                    if !ended.isEmpty {
                        Text("Ended in the last 24 hours")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .padding(.horizontal, 6)
                            .padding(.top, running.isEmpty ? 4 : 8)
                        ForEach(ended) { row($0) }
                    }
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
                .fill(session.state.color)
                .frame(width: 8, height: 8)
                .help(session.state.label)
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
    }

    private var detail: String {
        var parts: [String] = []
        if let model = session.model { parts.append(ModelName.display(model)) }
        switch session.state {
        case .busy:
            parts.append(session.state.label)
        case .waiting:
            parts.append(session.lastActivity.map { "Waiting · \(Fmt.ago($0, now: now))" } ?? session.state.label)
        case .idle:
            if let last = session.lastActivity { parts.append(Fmt.ago(last, now: now)) }
        }
        if let tokens = session.tokens {
            parts.append("\(Fmt.tokens(tokens.total(includingCacheReads: false))) tok")
        }
        return parts.joined(separator: " · ")
    }
}
