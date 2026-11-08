import SwiftUI

/// The user's own recent presses on a door — the local audit trail. "Used" means
/// the remote fired; the door has no sensor, so it can't say opened vs. closed.
struct GarageHistoryView: View {
    let door: GarageDoor
    let activity: [GarageActivity]

    var body: some View {
        NavigationStack {
            Group {
                if activity.isEmpty {
                    ContentUnavailableView("No history yet", systemImage: "clock",
                                           description: Text("Your presses will show up here."))
                } else {
                    List(activity) { a in
                        HStack(spacing: 14) {
                            Image(systemName: a.pressAgain && a.kind.isUse ? "hand.raised.fill" : Self.symbol(a.kind))
                                .font(.title3)
                                .foregroundStyle(Self.tint(a.kind).gradient)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.pressAgain ? "Stop / press again" + (a.kind.isUse ? "" : " · " + Self.label(a.kind))
                                                  : Self.label(a.kind))
                                Text(GarageDates.phrase(a.at).capitalizedFirst)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle(door.name)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    static func symbol(_ k: GarageActivity.Kind) -> String {
        switch k {
        case .done: "checkmark.circle.fill"
        case .sent: "questionmark.circle.fill"
        case .offline: "wifi.slash"
        case .refused, .expired: "hand.raised.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    static func tint(_ k: GarageActivity.Kind) -> Color {
        switch k {
        case .done: .green
        case .sent, .offline: .orange
        case .refused, .expired, .failed: .red
        }
    }

    static func label(_ k: GarageActivity.Kind) -> String {
        switch k {
        case .done: "Used"
        case .sent: "Not confirmed"
        case .offline: "Opener offline"
        case .refused: "Declined"
        case .expired: "Too late"
        case .failed: "Didn't go through"
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
