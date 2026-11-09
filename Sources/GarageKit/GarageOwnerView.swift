import SwiftUI
import UIKit

/// Owner tools: your doors (each opens its profile: name, color, travel time,
/// who can open it, the device), then adding a new device. Push it inside the
/// host's navigation stack; it brings no stack of its own. Hosts can append
/// their own sections (an account row, sign-out) through `extra`.
///
/// A grantee never needs this screen: show the entry point only when one of
/// `engine.doors` is `owned`.
public struct GarageOwnerView<Extra: View>: View {
    let engine: GarageEngine
    let allowsAddingDevices: Bool
    let extra: Extra

    @State private var shares: [UUID: Int] = [:]
    @State private var addingDevice = false
    @State private var message: String?

    public init(engine: GarageEngine, allowsAddingDevices: Bool = true, @ViewBuilder extra: () -> Extra) {
        self.engine = engine
        self.allowsAddingDevices = allowsAddingDevices
        self.extra = extra()
    }

    private var ownedDoors: [GarageDoor] { engine.doors.filter(\.owned) }

    public var body: some View {
        Form {
            Section {
                if ownedDoors.isEmpty {
                    ContentUnavailableView("No doors of your own", systemImage: "door.garage.closed",
                                           description: Text(allowsAddingDevices
                                                             ? "Add a device to set one up." : "Doors you own appear here."))
                }
                ForEach(ownedDoors) { door in
                    NavigationLink {
                        GarageDoorProfileView(engine: engine, doorID: door.id)
                    } label: {
                        GarageDoorRow(door: door, shares: shares[door.id])
                    }
                    .task(id: door.id) { await loadShares(door) }
                }
            } header: {
                if !ownedDoors.isEmpty { Text("Your doors") }
            }

            if allowsAddingDevices {
                Section {
                    Button { addingDevice = true } label: {
                        Label("Add a device", systemImage: "plus.circle")
                    }
                } footer: {
                    Text("Sets up a new board and its door. To add a door to a board you already have, open that door.")
                }
            }

            extra

            if let message {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Doors")
        .refreshable {
            await engine.refresh()
            for door in ownedDoors { await loadShares(door) }
        }
        .sheet(isPresented: $addingDevice) {
            GarageAddDeviceSheet(engine: engine)
        }
    }

    private func loadShares(_ door: GarageDoor) async {
        do {
            shares[door.id] = try await engine.listGrants(doorID: door.id)
                .filter { GarageSharing.isActive($0) }.count
            message = nil
        } catch is CancellationError {
        } catch {
            message = "Couldn't load who has access."
        }
    }
}

/// One door in a list: online dot, name, its color, and who can open it.
struct GarageDoorRow: View {
    let door: GarageDoor
    var shares: Int?

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(DoorTint(color: door.color))
                .frame(width: 22, height: 22)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(door.online ? Color.green : Color.gray)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 1.5))
                        .offset(x: 3, y: 3)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(door.name)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(door.online ? "Online" : "Offline")
    }

    private var subtitle: String {
        var parts = [door.online ? "Online" : "Offline"]
        switch shares {
        case .none: break
        case 0?: parts.append("Only you")
        case 1?: parts.append("Shared with 1 person")
        case let n?: parts.append("Shared with \(n) people")
        }
        return parts.joined(separator: " · ")
    }
}

public extension GarageOwnerView where Extra == EmptyView {
    init(engine: GarageEngine, allowsAddingDevices: Bool = true) {
        self.init(engine: engine, allowsAddingDevices: allowsAddingDevices) { EmptyView() }
    }
}

// MARK: - Share sheet

/// Pick one person (and optionally an end date) to share a door with.
struct GarageShareSheet: View {
    let door: GarageDoor
    let candidates: [GarageContact]
    let share: (GarageContact, Date?) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: GarageContact.ID?
    @State private var hasEnd = false
    @State private var end = Date.now.addingTimeInterval(24 * 3600)
    @State private var query = ""
    @State private var busy = false
    @State private var error: String?

    private var shown: [GarageContact] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? candidates : candidates.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if candidates.isEmpty {
                        Text("No one else to add. People appear here once you're connected with them.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(shown) { c in
                        Button { selection = c.id } label: {
                            HStack(spacing: 12) {
                                GarageAvatar(name: c.name, data: c.avatar)
                                Text(c.name).foregroundStyle(.primary)
                                Spacer()
                                if selection == c.id {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Share with")
                }

                Section {
                    Toggle("End date", isOn: $hasEnd.animation())
                    if hasEnd {
                        DatePicker("Until", selection: $end, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                    }
                } footer: {
                    Text(hasEnd ? "Access ends on its own at that time." : "Access lasts until you remove it.")
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .searchable(text: $query, prompt: "Search")
            .navigationTitle("Share \(door.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Share") { Task { await submit() } }
                        .disabled(selection == nil || busy)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func submit() async {
        guard let c = candidates.first(where: { $0.id == selection }) else { return }
        busy = true
        defer { busy = false }
        do {
            try await share(c, hasEnd ? end : nil)
            dismiss()
        } catch {
            self.error = "Couldn't share with \(c.name). They may not be able to see you yet."
        }
    }
}

// MARK: - Add a device sheet

/// Register a new device. It always creates a NEW door; the token is shown once.
struct GarageAddDeviceSheet: View {
    let engine: GarageEngine

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var registered: RegisteredDevice?
    @State private var busy = false
    @State private var error: String?
    @State private var copied = 0

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                if let registered {
                    Section {
                        Text(registered.deviceToken)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = registered.deviceToken
                            copied += 1
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .sensoryFeedback(.success, trigger: copied)
                    } header: {
                        Text("Device token")
                    } footer: {
                        Text("Enter this in the device's setup. It's shown only once.")
                    }
                } else {
                    Section {
                        TextField("Name", text: $name, prompt: Text("e.g. Side door"))
                            .submitLabel(.done)
                    } footer: {
                        if let clash = GarageSharing.nameClash(name, in: engine.doors) {
                            Text("You already have a door named “\(clash.name)”. This adds a second, separate door.")
                        } else {
                            Text("Adds a new door to your account. Your existing doors aren't changed.")
                        }
                    }
                    if let error {
                        Section { Text(error).foregroundStyle(.red) }
                    }
                }
            }
            .navigationTitle(registered == nil ? "Add a device" : "Device added")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(registered != nil && copied == 0)
            .toolbar {
                if registered == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") { Task { await add() } }
                            .disabled(trimmed.isEmpty || busy)
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
    }

    private func add() async {
        busy = true
        defer { busy = false }
        do {
            registered = try await engine.registerDevice(name: trimmed)
            error = nil
        } catch {
            self.error = "Couldn't add the device."
        }
    }
}

// MARK: - Avatar

/// A round profile image, or initials when there isn't one.
struct GarageAvatar: View {
    let name: String
    let data: Data?
    var size: CGFloat = 34

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.tint.opacity(0.15))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let s = parts.compactMap(\.first).map(String.init).joined()
        return s.isEmpty ? "?" : s.uppercased()
    }
}
