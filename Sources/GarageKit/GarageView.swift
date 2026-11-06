import SwiftUI

/// The kit's root view: the backdrop plus one trigger per door (paged when there
/// are several). Pure — it reads the engine; the host owns start/stop.
public struct GarageView: View {
    @Bindable var engine: GarageEngine
    var appearance: GarageAppearance
    @State private var selection: UUID?

    public init(engine: GarageEngine, appearance: GarageAppearance = .standard) {
        self.engine = engine
        self.appearance = appearance
    }

    private var focused: GarageDoor? {
        engine.doors.first { $0.id == selection } ?? engine.doors.first
    }

    public var body: some View {
        ZStack {
            GarageBackdrop(tint: focused.map { GarageStyle.tint(engine.phase(for: $0), online: $0.online) } ?? .cyan)
                .ignoresSafeArea()
            content
        }
        // Dark inside the garage screen only. preferredColorScheme would flip the
        // host's whole window (the entire app) while this view is on screen.
        .environment(\.colorScheme, .dark)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    @ViewBuilder
    private var content: some View {
        switch (engine.loadState, engine.doors.count) {
        case (.loading, 0), (.idle, 0):
            ProgressView().controlSize(.large)
        case (.failed(let message), 0):
            ContentUnavailableView {
                Label("Unavailable", systemImage: "wifi.exclamationmark")
                    .symbolEffect(.pulse)
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await engine.refresh() } }
                    .buttonStyle(.glass)
            }
        case (_, 0):
            ContentUnavailableView("No doors yet", systemImage: "door.garage.closed",
                                   description: Text("Nothing has been shared with you."))
        case (_, 1):
            GarageTriggerButton(door: engine.doors[0], engine: engine, appearance: appearance)
        default:
            TabView(selection: $selection) {
                ForEach(engine.doors) { door in
                    GarageTriggerButton(door: door, engine: engine, appearance: appearance)
                        .tag(Optional(door.id))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
        }
    }
}

/// A slow, living mesh gradient, tinted by the focused door's state. Static when
/// Reduce Motion is on.
struct GarageBackdrop: View {
    var tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 12, paused: reduceMotion)) { ctx in
            let t = reduceMotion ? 0 : Float(ctx.date.timeIntervalSinceReferenceDate)
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5 + 0.08 * sin(t * 0.35)],
                    [0.5 + 0.12 * sin(t * 0.27), 0.45 + 0.10 * cos(t * 0.31)],
                    [1, 0.5 + 0.08 * cos(t * 0.29)],
                    [0, 1], [0.5, 1], [1, 1],
                ],
                colors: [
                    .black, Color(white: 0.06), .black,
                    tint.opacity(0.10), tint.opacity(0.32), tint.opacity(0.08),
                    .black, Color(white: 0.05), .black,
                ]
            )
        }
        .animation(.smooth(duration: 0.8), value: tint)
    }
}
