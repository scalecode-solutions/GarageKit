import SwiftUI
import UIKit

/// Owner tools: your doors first (rename, who has access, share, remove
/// access), then the dial setting, then adding a new device. Push it inside the
/// host's navigation stack; it brings no stack of its own. Hosts can append their
/// own sections (an account row, sign-out) through `extra`.
///
/// A grantee never needs this screen: show the entry point only when one of
/// `engine.doors` is `owned`.
public struct GarageOwnerView<Extra: View>: View {
    let engine: GarageEngine
    let allowsAddingDevices: Bool
    let extra: Extra

    @State private var names: [UUID: String] = [:]
    @State private var grants: [UUID: [GarageGrant]] = [:]
    @State private var contacts: [GarageContact] = []
    @State private var message: String?
    @State private var sharing: GarageDoor?
    @State private var addingDevice = false
    @State private var removing: GarageGrant?

    public init(engine: GarageEngine, allowsAddingDevices: Bool = true, @ViewBuilder extra: () -> Extra) {
        self.engine = engine
        self.allowsAddingDevices = allowsAddingDevices
        self.extra = extra()
    }

    private var ownedDoors: [GarageDoor] { engine.doors.filter(\.owned) }
    private var owner: UUID { engine.config.currentUserID }

    public var body: some View {
        Form {
            if ownedDoors.isEmpty {
                Section {
                    ContentUnavailableView("No doors of your own", systemImage: "door.garage.closed",
                                           description: Text(allowsAddingDevices
                                                             ? "Add a device to set one up." : "Doors you own appear here."))
                }
            }

            ForEach(ownedDoors) { door in
                doorSection(door)
                    .task(id: door.id) { await loadGrants(door) }
            }

            Section {
                Stepper(value: motionSeconds, in: 2...20, step: 0.5) {
                    LabeledContent("Door motion", value: "\(motionSeconds.wrappedValue.formatted()) s")
                }
            } header: {
                Text("Dial")
            } footer: {
                Text("How long the dial shows the door moving after a confirmed press, on this device. Time your door and match it.")
            }

            if allowsAddingDevices {
                Section {
                    Button { addingDevice = true } label: {
                        Label("Add a device", systemImage: "plus.circle")
                    }
                } footer: {
                    Text("Sets up a new door. Your existing doors aren't changed.")
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
        .task { await loadContacts() }
        .refreshable {
            await engine.refresh()
            await loadContacts()
            for door in ownedDoors { await loadGrants(door) }
        }
        .sheet(item: $sharing) { door in
            GarageShareSheet(
                door: door,
                candidates: GarageSharing.candidates(contacts: contacts, grants: grants[door.id] ?? [], owner: owner)
            ) { contact, until in
                _ = try await engine.createGrant(doorID: door.id, granteeID: contact.id,
                                                 label: contact.name, expiresAt: until)
                await loadGrants(door)
            }
        }
        .sheet(isPresented: $addingDevice) {
            GarageAddDeviceSheet(engine: engine)
        }
        .confirmationDialog(
            removing.map { "Remove \(GarageSharing.displayName(for: $0, contacts: contacts))'s access?" } ?? "",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { grant in
            Button("Remove access", role: .destructive) { Task { await remove(grant) } }
        } message: { _ in
            Text("Their access ends right away. You can share again later.")
        }
    }

    // MARK: door section

    @ViewBuilder
    private func doorSection(_ door: GarageDoor) -> some View {
        Section {
            HStack {
                TextField("Door name", text: nameBinding(door))
                    .submitLabel(.done)
                    .onSubmit { Task { await rename(door) } }
                if trimmedName(door) != door.name && !trimmedName(door).isEmpty {
                    Button("Save") { Task { await rename(door) } }
                        .buttonStyle(.borderless)
                        .transition(.opacity)
                }
            }
            .animation(.smooth, value: names[door.id])

            HStack(spacing: 8) {
                Circle()
                    .fill(door.online ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(door.online ? "Online" : "Offline")
                    .foregroundStyle(.secondary)
            }

            if let list = grants[door.id] {
                if list.isEmpty {
                    Text("Only you can open this door.")
                        .foregroundStyle(.secondary)
                }
                ForEach(list) { grant in
                    personRow(grant)
                        .swipeActions {
                            Button("Remove", role: .destructive) { removing = grant }
                        }
                        .contextMenu {
                            Button("Remove access", systemImage: "person.badge.minus", role: .destructive) {
                                removing = grant
                            }
                        }
                }
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
            }

            Button { sharing = door } label: {
                Label("Share…", systemImage: "person.badge.plus")
            }
        } header: {
            Text(door.name)
        } footer: {
            if !(grants[door.id] ?? []).isEmpty {
                Text("Swipe a person to remove their access.")
            }
        }
    }

    private func personRow(_ grant: GarageGrant) -> some View {
        let name = GarageSharing.displayName(for: grant, contacts: contacts)
        let avatar = contacts.first { $0.id == grant.granteeID }?.avatar
        return HStack(spacing: 12) {
            GarageAvatar(name: name, data: avatar)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(grant.expiresAt.map { "Until \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "No end date")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: actions

    private var motionSeconds: Binding<Double> {
        Binding(
            get: {
                let c = engine.motionDuration.components
                return Double(c.seconds) + Double(c.attoseconds) / 1e18
            },
            set: { engine.motionDuration = .milliseconds(Int($0 * 1000)) }
        )
    }

    private func nameBinding(_ door: GarageDoor) -> Binding<String> {
        Binding(get: { names[door.id] ?? door.name }, set: { names[door.id] = $0 })
    }

    private func trimmedName(_ door: GarageDoor) -> String {
        (names[door.id] ?? door.name).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func rename(_ door: GarageDoor) async {
        let name = trimmedName(door)
        guard !name.isEmpty, name != door.name else { return }
        do {
            try await engine.renameDoor(door, to: name)
            names[door.id] = nil
            message = nil
        } catch { message = "Couldn't rename the door." }
    }

    private func remove(_ grant: GarageGrant) async {
        removing = nil
        do {
            try await engine.revokeGrant(id: grant.id)
            if let door = ownedDoors.first(where: { $0.id == grant.doorID }) { await loadGrants(door) }
            message = nil
        } catch { message = "Couldn't remove access. Try again." }
    }

    /// On failure keep the last list and say so: an empty list would read as
    /// "nobody has access" when we just couldn't ask.
    private func loadGrants(_ door: GarageDoor) async {
        do {
            grants[door.id] = try await engine.listGrants(doorID: door.id)
        } catch is CancellationError {
        } catch {
            message = "Couldn't load who has access."
        }
    }

    private func loadContacts() async {
        do {
            contacts = try await engine.listContacts()
        } catch is CancellationError {
        } catch {
            message = "Couldn't load your contacts."
        }
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
