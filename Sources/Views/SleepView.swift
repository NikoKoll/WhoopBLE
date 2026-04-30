import SwiftUI

struct SleepView: View {
    @ObservedObject var sync: SyncManager

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if sync.sleepSessions.isEmpty {
                emptyState
            } else {
                sessionList
            }
        }
        .navigationTitle("Sleep")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 52))
                .foregroundStyle(.indigo.opacity(0.55))
            Text("No sleep data yet")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text("Sleep sessions are detected from synced WHOOP history.\nConnect your strap to start syncing.")
                .font(.caption)
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            if sync.isSyncing {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6).tint(.cyan)
                    Text("Syncing history…")
                        .font(.caption2)
                        .foregroundStyle(.cyan)
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Session List

    private var sessionList: some View {
        ScrollView {
            VStack(spacing: 1) {
                if sync.isSyncing {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.55).tint(.cyan)
                        Text("Still syncing…")
                            .font(.caption2)
                            .foregroundStyle(.cyan)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                }
                ForEach(sync.sleepSessions.reversed(), id: \.start) { session in
                    SleepSessionRow(session: session)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    Divider()
                        .background(Color.white.opacity(0.07))
                        .padding(.horizontal, 16)
                }
            }
            .padding(.top, 8)
        }
    }
}

// MARK: - Session Row

private struct SleepSessionRow: View {
    let session: SleepSession

    private var durationText: String {
        let secs = Int(session.end.timeIntervalSince(session.start))
        let h = secs / 3600
        let m = (secs % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private var qualityColor: Color {
        let hours = session.end.timeIntervalSince(session.start) / 3600
        switch hours {
        case 7...: return .green
        case 5...: return .yellow
        default:   return .orange
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            // Night icon with quality tint
            ZStack {
                Circle()
                    .fill(qualityColor.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: "moon.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(qualityColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(session.start.formatted(date: .abbreviated, time: .omitted))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                HStack(spacing: 4) {
                    Text(session.start.formatted(date: .omitted, time: .shortened))
                    Text("→")
                    Text(session.end.formatted(date: .omitted, time: .shortened))
                }
                .font(.caption)
                .foregroundStyle(.gray)
            }

            Spacer()

            Text(durationText)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(qualityColor)
        }
    }
}
