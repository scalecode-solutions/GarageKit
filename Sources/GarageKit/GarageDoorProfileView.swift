import SwiftUI

/// One door's profile, for its owner: name, color, travel time, who can open
/// it, and the device behind it (plus adding another door to that device).
/// Pushed from `GarageOwnerView` (or by a host that links straight to a
/// door's settings); reads the live door from the engine by id.
public struct GarageDoorProfileView: View {
    let engine: GarageEngine
    let doorID: UUID

    public init(engine: GarageEngine, doorID: UUID) {
        self.engine = engine
        self.doorID = doorID
    }

    @Environment(\.colorScheme) private var colorScheme
    @State private var name = ""
    @State private var motionSeconds: Double = 12
    @State private var grants: [GarageGrant]?
    @State private var contacts: [GarageContact] = []
    @State private var sharing = false
    @State private var removing: GarageGrant?
    @State private var addingDoor = false
    @State private var message: String?
    @State private var saved = 0

    private var door: GarageDoor? { engine.doors.first { $0.id == doorID } }
    private var owner: UUID { engine.config.currentUserID }

    public var body: some View {
        Group {
            if let door {
                form(door)
            } else {
                ContentUnavailableView("Door removed", systemImage: "door.garage.closed")
            }
        }
        .navigationTitle(door?.name ?? "Door")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: saved)
    }

    private func form(_ door: GarageDoor) -> some View {
        Form {
            // Name, with the online dot in front (MVGARA-18).
            Section {
                HStack(spacing: 10) {
                    Circle()
                        .fill(door.online ? Color.green : Color.gray)
                        .frame(width: 9, height: 9)
                        .accessibilityLabel(door.online ? "Online" : "Offline")
                    TextField("Door name", text: $name)
                        .submitLabel(.done)
                        .onSubmit { Task { await saveName(door) } }
                    if trimmedName != door.name && !trimmedName.isEmpty {
                        Button("Save") { Task { await saveName(door) } }
                            .buttonStyle(.borderless)
                    }
                }
            } footer: {
                Text(door.online ? "Online now." : "The opener isn't connected right now.")
            }

            colorSection(door)
            motionSection(door)
            sharingSection(door)
            deviceSection(door)

            if let message {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            name = door.name
            motionSeconds = seconds(engine.motion(for: door))
        }
        .task(id: door.id) {
            await loadGrants()
            await loadContacts()
        }
        .refreshable {
            await engine.refresh()
            await loadGrants()
        }
        .sheet(isPresented: $sharing) {
            GarageShareSheet(
                door: door,
                candidates: GarageSharing.candidates(contacts: contacts, grants: grants ?? [], owner: owner)
            ) { contact, until in
                _ = try await engine.createGrant(doorID: door.id, granteeID: contact.id,
                                                 label: contact.name, expiresAt: until)
                await loadGrants()
            }
        }
        .sheet(isPresented: $addingDoor) {
            if let device = door.device {
                GarageAddDoorSheet(engine: engine, device: device, taken: engine.doorsOnDevice(of: door).map(\.button))
            }
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

    // MARK: color

    private func colorSection(_ door: GarageDoor) -> some View {
        Section {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 12) {
                ForEach(GarageDoorColor.palette, id: \.self) { c in
                    let selected = door.color == c || (door.color == .standard && c == .cyan)
                    Button {
                        Task { await save(door, color: c) }
                    } label: {
                        Circle()
                            .fill(c.color(dark: colorScheme == .dark))
                            .frame(height: 36)
                            .overlay {
                                if selected {
                                    Image(systemName: "checkmark")
                                        .font(.footnote.weight(.bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .overlay(Circle().strokeBorder(.primary.opacity(selected ? 0.35 : 0), lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(c.label)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Color")
        } footer: {
            Text("Shown on the dial and in lists, for everyone who can open this door.")
        }
    }

    // MARK: travel time

    private func motionSection(_ door: GarageDoor) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Travel time", value: "\(Int(motionSeconds)) s")
                Slider(value: $motionSeconds, in: 3...30, step: 1) { editing in
                    if !editing { Task { await save(door, motion: .seconds(Int(motionSeconds))) } }
                }
                .accessibilityLabel("Travel time")
                .accessibilityValue("\(Int(motionSeconds)) seconds")
            }
            if door.motion != nil {
                Button("Use the default (\(Int(seconds(engine.motionDuration))) s)") {
                    Task {
                        await save(door, motion: .zero)
                        motionSeconds = seconds(engine.motionDuration)
                    }
                }
            }
        } header: {
            Text("Door")
        } footer: {
            Text("How long the dial shows the door moving after a press. Time your door and match it; everyone who opens it sees the same.")
        }
    }

    // MARK: sharing

    private func sharingSection(_ door: GarageDoor) -> some View {
        Section {
            if let list = grants {
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
            Button { sharing = true } label: {
                Label("Share…", systemImage: "person.badge.plus")
            }
        } header: {
            Text("Who can open it")
        } footer: {
            if !(grants ?? []).isEmpty {
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
                Text(GarageSharing.accessLine(grant))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: device

    @ViewBuilder
    private func deviceSection(_ door: GarageDoor) -> some View {
        if let dev = door.device {
            let siblings = engine.doorsOnDevice(of: door).filter { $0.id != door.id }
            Section {
                LabeledContent("Status", value: door.online ? "Online" : "Offline")
                if !dev.firmware.isEmpty {
                    LabeledContent("Firmware", value: dev.firmware)
                }
                if let signal = dev.signal, let rssi = dev.rssi {
                    LabeledContent("Wi-Fi", value: "\(signal) (\(rssi) dBm)")
                }
                if let seen = dev.lastSeen {
                    LabeledContent("Last connected") {
                        Text(seen, format: .relative(presentation: .named))
                    }
                }
                if door.button > 0 {
                    LabeledContent("Remote button", value: "\(door.button)")
                }
                ForEach(siblings) { other in
                    LabeledContent("Also on this board", value: "\(other.name) (button \(other.button))")
                }
                if engine.doorsOnDevice(of: door).count < 4 {
                    Button { addingDoor = true } label: {
                        Label("Add a door on this board", systemImage: "plus.rectangle.on.rectangle")
                    }
                }
            } header: {
                Text("Device")
            } footer: {
                Text("Only you see this.")
            }
        }
    }

    // MARK: actions

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func seconds(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }

    private func saveName(_ door: GarageDoor) async {
        let n = trimmedName
        guard !n.isEmpty, n != door.name else { return }
        await save(door, name: n)
    }

    private func save(_ door: GarageDoor, name: String? = nil, motion: Duration? = nil, color: GarageDoorColor? = nil) async {
        do {
            try await engine.updateDoor(door, name: name, motion: motion, color: color)
            message = nil
            saved += 1
        } catch {
            message = "Couldn't save. Try again."
            // Put the controls back to what the server has.
            if let d = self.door {
                self.name = d.name
                motionSeconds = seconds(engine.motion(for: d))
            }
        }
    }

    private func remove(_ grant: GarageGrant) async {
        removing = nil
        do {
            try await engine.revokeGrant(id: grant.id)
            await loadGrants()
            message = nil
        } catch { message = "Couldn't remove access. Try again." }
    }

    /// On failure keep the last list and say so: an empty list would read as
    /// "nobody has access" when we just couldn't ask.
    private func loadGrants() async {
        do {
            grants = try await engine.listGrants(doorID: doorID)
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

// MARK: - Add a door on this board

/// Another door on an existing board: a name and which remote button drives it.
struct GarageAddDoorSheet: View {
    let engine: GarageEngine
    let device: GarageDeviceStatus
    let taken: [Int]

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var button = 0
    @State private var busy = false
    @State private var error: String?

    private var free: [Int] { (1...4).filter { !taken.contains($0) } }
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("e.g. West door"))
                        .submitLabel(.done)
                }
                Section {
                    Picker("Remote button", selection: $button) {
                        ForEach(free, id: \.self) { b in Text("Button \(b)").tag(b) }
                    }
                } footer: {
                    Text(GarageSharing.buttonNote(button, wired: device.buttons))
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Add a door")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await add() } }
                        .disabled(trimmed.isEmpty || button == 0 || busy)
                }
            }
            .onAppear { if button == 0 { button = free.first ?? 0 } }
        }
        .presentationDetents([.medium])
    }

    private func add() async {
        busy = true
        defer { busy = false }
        do {
            try await engine.addDoor(on: device, name: trimmed, button: button)
            dismiss()
        } catch {
            self.error = "Couldn't add the door. That button may already open another one."
        }
    }
}
