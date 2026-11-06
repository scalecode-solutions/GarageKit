import SwiftUI
import UIKit
import GarageKit

/// Owner tools for setting up tests without curl: register a device (shows its
/// token once — paste into `fakedevice -token …` or the C3 firmware), grant a
/// user by mvServer ID, revoke. A grantee's side of the app never shows any of this.
struct OwnerView: View {
    let engine: GarageEngine
    let userID: String
    let signOut: () -> Void

    @State private var newDoorName = "Garage"
    @State private var names: [UUID: String] = [:]
    @State private var registered: RegisteredDevice?
    // Drafts are per door, so typing in one door's section can't grant another.
    @State private var granteeIDs: [UUID: String] = [:]
    @State private var grantLabels: [UUID: String] = [:]
    @State private var grants: [UUID: [GarageGrant]] = [:]
    @State private var message: String?
    @State private var copied = 0

    private var ownedDoors: [GarageDoor] { engine.doors.filter(\.owned) }

    var body: some View {
        NavigationStack {
            Form {
                Section("You") {
                    LabeledContent("User ID") {
                        Text(userID).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Button("Sign out", role: .destructive, action: signOut)
                }

                Section {
                    Stepper(value: motionSeconds, in: 2...20, step: 0.5) {
                        LabeledContent("Door motion", value: "\(motionSeconds.wrappedValue.formatted()) s")
                    }
                } header: {
                    Text("Dial")
                } footer: {
                    Text("How long the dial shows the door moving after a confirmed press. Time your door and match it.")
                }

                Section {
                    TextField("Name for the new device", text: $newDoorName)
                    Button("Register new device") { Task { await register() } }
                    if let registered {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Device token (shown once)").font(.caption).foregroundStyle(.secondary)
                            Text(registered.deviceToken).font(.caption.monospaced()).textSelection(.enabled)
                            Button {
                                UIPasteboard.general.string = registered.deviceToken
                                copied += 1
                            } label: {
                                Label("Copy token", systemImage: "doc.on.doc")
                                    .contentTransition(.symbolEffect(.replace))
                            }
                            .sensoryFeedback(.success, trigger: copied)
                        }
                    }
                } header: {
                    Text("Devices")
                } footer: {
                    Text("Run: fakedevice -token <token>  — or flash it into the C3.")
                }

                ForEach(ownedDoors) { door in
                    Section(door.name) {
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
                        LabeledContent("Online") {
                            Image(systemName: door.online ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(door.online ? .green : .secondary)
                        }
                        TextField("Grantee user ID", text: draft($granteeIDs, door))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.caption.monospaced())
                        TextField("Label", text: draft($grantLabels, door))
                        Button("Grant access") { Task { await grant(door) } }
                            .disabled(UUID(uuidString: granteeIDs[door.id] ?? "") == nil)
                        ForEach(grants[door.id] ?? []) { g in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(g.label.isEmpty ? "Grant" : g.label)
                                    Text(g.granteeID.uuidString).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Revoke", role: .destructive) { Task { await revoke(g, door) } }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                    .task { await loadGrants(door) }
                }

                if let message {
                    Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Owner")
            .refreshable {
                await engine.refresh()
                for door in ownedDoors { await loadGrants(door) }
            }
        }
    }

    private func register() async {
        do {
            registered = try await engine.registerDevice(name: newDoorName)
            message = nil
        } catch { message = "Register failed: \(error)" }
    }

    private var motionSeconds: Binding<Double> {
        Binding(
            get: {
                let c = engine.motionDuration.components
                return Double(c.seconds) + Double(c.attoseconds) / 1e18
            },
            set: { engine.motionDuration = .milliseconds(Int($0 * 1000)) }
        )
    }

    private func draft(_ store: Binding<[UUID: String]>, _ door: GarageDoor) -> Binding<String> {
        Binding(get: { store.wrappedValue[door.id] ?? "" }, set: { store.wrappedValue[door.id] = $0 })
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
        } catch { message = "Rename failed: \(error)" }
    }

    private func grant(_ door: GarageDoor) async {
        guard let gid = UUID(uuidString: granteeIDs[door.id] ?? "") else { return }
        do {
            _ = try await engine.createGrant(doorID: door.id, granteeID: gid, label: grantLabels[door.id] ?? "")
            granteeIDs[door.id] = nil
            grantLabels[door.id] = nil
            await loadGrants(door)
        } catch { message = "Grant failed: \(error)" }
    }

    private func revoke(_ g: GarageGrant, _ door: GarageDoor) async {
        do {
            try await engine.revokeGrant(id: g.id)
            await loadGrants(door)
        } catch { message = "Revoke failed: \(error)" }
    }

    /// On failure keep the last list and say so — an empty list would look like
    /// "nobody has access" when we just couldn't ask.
    private func loadGrants(_ door: GarageDoor) async {
        do {
            grants[door.id] = try await engine.listGrants(doorID: door.id)
        } catch is CancellationError {
        } catch {
            message = "Couldn't load grants: \(error)"
        }
    }
}
