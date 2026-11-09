import SwiftUI

/// The kit's root view: the backdrop plus one trigger per door (paged when there
/// are several). Pure — it reads the engine; the host owns start/stop.
public struct GarageView: View {
    @Bindable var engine: GarageEngine
    var appearance: GarageAppearance

    public init(engine: GarageEngine, appearance: GarageAppearance = .standard) {
        self.engine = engine
        self.appearance = appearance
    }

    @Environment(\.colorScheme) private var colorScheme

    private var focused: GarageDoor? { engine.focusedDoor }

    /// The swipe pages and the title menu both drive the engine's selection, so
    /// they agree and it's remembered.
    private var selection: Binding<UUID?> {
        Binding(get: { engine.focusedDoor?.id }, set: { engine.selectedDoorID = $0 })
    }

    public var body: some View {
        ZStack {
            GarageBackdrop(tint: focused.map {
                GarageStyle.tint(engine.phase(for: $0), online: $0.online,
                                 idle: $0.color.color(dark: colorScheme == .dark))
            } ?? .cyan)
                .ignoresSafeArea()
            content
        }
        .modifier(DoorSwitcher(engine: engine, selection: selection))
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
            TabView(selection: selection) {
                ForEach(engine.doors) { door in
                    GarageTriggerButton(door: door, engine: engine, appearance: appearance)
                        .tag(Optional(door.id))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
        }
    }
}

/// With two or more doors, the navigation title becomes the focused door's
/// name with a menu to switch ("East Door ▾"), alongside the swipe pages. With
/// one door the host's own title stays.
struct DoorSwitcher: ViewModifier {
    let engine: GarageEngine
    let selection: Binding<UUID?>

    func body(content: Content) -> some View {
        if engine.doors.count > 1, let focused = engine.focusedDoor {
            content
                .navigationTitle(focused.name)
                // Inline: iOS shows the menu's chevron ("East Door ▾") only on
                // an inline title, and a large one would repeat the dial's name.
                .navigationBarTitleDisplayMode(.inline)
                .toolbarTitleMenu {
                    ForEach(engine.doors) { door in
                        Button {
                            withAnimation(.smooth) { selection.wrappedValue = door.id }
                        } label: {
                            Label {
                                Text(door.name)
                            } icon: {
                                Image(systemName: door.id == focused.id ? "checkmark.circle.fill" : "circle.fill")
                                    .foregroundStyle(DoorTint(color: door.color))
                            }
                        }
                    }
                }
        } else {
            content
        }
    }
}

/// A slow, living mesh gradient, tinted by the focused door's state. Static when
/// Reduce Motion is on. Follows the host's color scheme: deep edges in dark,
/// soft ones in light, the tinted glow in the middle either way.
struct GarageBackdrop: View {
    var tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var dark: Bool { colorScheme == .dark }
    private var edge: Color { dark ? .black : Color(white: 0.97) }
    private var rim: Color { dark ? Color(white: 0.06) : Color(white: 0.93) }
    private var base: Color { dark ? .black : .white }

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
                    edge, rim, edge,
                    tint.opacity(0.10), tint.opacity(dark ? 0.32 : 0.24), tint.opacity(0.08),
                    edge, rim, edge,
                ]
            )
        }
        // The tinted stops are translucent: an opaque base keeps whatever the host
        // has underneath from bleeding through.
        .background(base)
        .animation(.smooth(duration: 0.8), value: tint)
    }
}
