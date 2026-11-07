import SwiftUI

/// The trigger: one big glass dial. Press and hold (default) — a ring fills under
/// your thumb with building haptics, and when it completes the door is triggered.
/// Let go early and the ring unwinds; nothing fires.
///
/// Sequence: static door (idle) → ring (hold) → rings ripple out from the dial
/// (sending) → the door
/// breathes while it travels (`motionDuration`, after a confirmed press) →
/// checkmark → idle. Ring colour shows the real broadcast time: rings emitted
/// while waiting are cyan; rings emitted after the ack take the result colour
/// (green / orange / red). While the door is moving, a small "Stop / press again"
/// control appears under the dial (tap, not hold).
public struct GarageTriggerButton: View {
    public let door: GarageDoor
    @Bindable var engine: GarageEngine
    var appearance: GarageAppearance

    /// Hold time to fire.
    var holdDuration: Double = 0.6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var holdProgress: CGFloat = 0
    @State private var pressing = false
    /// Set when a hold begins in a state that may fire; a hold that starts while
    /// a press is in flight can never fire (no silent second toggle).
    @State private var armed = false
    @State private var firedThisPress = false
    @State private var holdTask: Task<Void, Never>?
    @State private var tickLevel = 0
    @State private var tick = 0
    @State private var fireBump = 0
    @State private var successBump = 0
    @State private var warnBump = 0
    @State private var errorBump = 0
    @State private var ackBump = 0
    @State private var againBump = 0
    @State private var burst = 0
    @State private var showHistory = false
    /// The broadcast ripple: when it started (nil = not shown), when the ack
    /// landed and in what colour, and when new rings stop being emitted (rings
    /// already in flight finish spreading).
    @State private var rippleStart: Date?
    @State private var rippleAckAt: Date?
    @State private var rippleAckTint: Color = .green
    @State private var rippleStopEmit: Date?
    @State private var rippleEndTask: Task<Void, Never>?

    public init(door: GarageDoor, engine: GarageEngine, appearance: GarageAppearance = .standard) {
        self.door = door
        self.engine = engine
        self.appearance = appearance
    }

    private var phase: GarageEngine.Phase { engine.phase(for: door) }
    private var moving: Bool { phase == .moving }
    private var holdToTrigger: Bool { engine.config.holdToTrigger }
    private var status: String {
        GarageStyle.status(phase, online: door.online, hold: holdToTrigger, appearance: appearance)
    }

    public var body: some View {
        VStack(spacing: 28) {
            dial
                .modifier(TriggerGesture(hold: holdToTrigger, duration: holdDuration,
                                         holdCompleted: holdCompleted, tapped: fire,
                                         pressingChanged: pressingChanged))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(door.name)
                .accessibilityValue(status)
                .accessibilityHint("Opens or closes the door")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { fire() }

            caption
        }
        .sensoryFeedback(trigger: tick) { _, _ in
            .impact(flexibility: .soft, intensity: min(1, 0.25 + Double(tickLevel) * 0.15))
        }
        .sensoryFeedback(.impact(weight: .heavy), trigger: fireBump)
        .sensoryFeedback(.impact(weight: .light), trigger: ackBump)
        .sensoryFeedback(.impact(weight: .medium), trigger: againBump)
        .sensoryFeedback(.success, trigger: successBump)
        .sensoryFeedback(.warning, trigger: warnBump)
        .sensoryFeedback(.error, trigger: errorBump)
        .onChange(of: phase) { _, new in phaseChanged(new) }
    }

    // MARK: dial

    private var tint: Color { GarageStyle.tint(phase, online: door.online) }

    private var dial: some View {
        ZStack {
            // Soft glow that swells as the ring fills.
            Circle()
                .fill(tint.gradient)
                .blur(radius: 46)
                .opacity(0.30 + 0.35 * holdProgress)
                .scaleEffect(0.85 + 0.2 * holdProgress)

            // Success burst — invisible at rest; skipped with Reduce Motion.
            if !reduceMotion {
                Circle()
                    .stroke(tint, lineWidth: 3)
                    .keyframeAnimator(initialValue: Burst(), trigger: burst) { content, v in
                        content.scaleEffect(v.scale).opacity(v.opacity)
                    } keyframes: { _ in
                        KeyframeTrack(\.scale) {
                            LinearKeyframe(1.0, duration: 0.01)
                            SpringKeyframe(1.6, duration: 0.8, spring: .smooth)
                        }
                        KeyframeTrack(\.opacity) {
                            LinearKeyframe(0.9, duration: 0.01)
                            LinearKeyframe(0, duration: 0.8)
                        }
                    }
            }

            // Broadcast: rings ripple outward from the dial's edge while sending.
            if let start = rippleStart, !reduceMotion {
                RippleRings(start: start, sendTint: .cyan, ackAt: rippleAckAt,
                            ackTint: rippleAckTint, stopEmitAt: rippleStopEmit)
                    .transition(.opacity)
            }

            // The glass body.
            Circle()
                .fill(.clear)
                .glassEffect(.regular.tint(tint.opacity(0.18)).interactive(), in: .circle)

            // Track + hold ring.
            Circle()
                .stroke(.primary.opacity(0.08), lineWidth: 8)
                .padding(10)
            Circle()
                .trim(from: 0, to: holdProgress)
                .stroke(AngularGradient(colors: [tint.opacity(0.35), tint, tint], center: .center),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(10)

            // The symbol. Static at idle (nothing is happening); it only breathes
            // while the door is actually travelling after a confirmed press.
            Image(systemName: GarageStyle.symbol(phase))
                .font(.system(size: 78, weight: .semibold))
                .foregroundStyle(tint.gradient)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.breathe.pulse, options: .repeat(.continuous),
                              isActive: moving && !reduceMotion)
                .symbolEffect(.bounce, value: successBump)
                .symbolEffect(.wiggle, value: errorBump)
                .scaleEffect(1 - 0.08 * holdProgress)
        }
        .frame(width: 240, height: 240)
        .scaleEffect(pressing ? 0.96 : 1)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0.35), value: pressing)
        .animation(.smooth(duration: 0.45), value: phase)
        .animation(.easeOut(duration: 0.4), value: rippleStart)
        .contentShape(.circle)
    }

    private var caption: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(door.online ? .green : .secondary)
                    .symbolEffect(.pulse, options: .repeat(.continuous),
                                  isActive: door.online && !reduceMotion)
                Text(door.name)
                    .font(.title2.weight(.semibold))
            }
            Text(status)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .animation(.smooth, value: phase)

            if let last = engine.lastUsed(door) {
                Button { showHistory = true } label: {
                    Label {
                        // Re-evaluated each minute so "today" becomes "yesterday"
                        // at midnight — but it never ticks like a counter.
                        TimelineView(.everyMinute) { ctx in
                            Text("Last used \(GarageDates.phrase(last, now: ctx.date))")
                        }
                    } icon: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if engine.canPressAgain(door) {
                Button {
                    againBump += 1
                    Task { await engine.pressAgain(door) }
                } label: {
                    Label("Stop / press again", systemImage: "hand.raised.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.glass)
                .padding(.top, 10)
                .accessibilityHint("Stops the door if it's moving; press again to reverse it")
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .multilineTextAlignment(.center)
        .animation(.smooth, value: engine.lastUsed(door))
        .animation(.smooth, value: engine.canPressAgain(door))
        .sheet(isPresented: $showHistory) {
            GarageHistoryView(door: door, activity: engine.activity[door.id] ?? [])
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: behaviour

    private func pressingChanged(_ isPressing: Bool) {
        if isPressing {
            // Arm only if a press may start now; otherwise the hold does nothing.
            armed = engine.canTrigger(door)
            guard armed else { return }
            pressing = true
            firedThisPress = false
            tickLevel = 0
            withAnimation(.linear(duration: holdDuration)) { holdProgress = 1 }
            holdTask?.cancel()
            let step = holdDuration / 5
            holdTask = Task { @MainActor in
                for level in 1...4 {
                    try? await Task.sleep(for: .seconds(step))
                    if Task.isCancelled { return }
                    tickLevel = level
                    tick += 1
                }
            }
        } else {
            pressing = false
            armed = false
            holdTask?.cancel()
            if !firedThisPress {
                withAnimation(.spring(duration: 0.45, bounce: 0.2)) { holdProgress = 0 }
            }
        }
    }

    /// The hold completed: fire only if this hold was armed.
    private func holdCompleted() {
        guard armed else { return }
        armed = false
        fire()
    }

    private func fire() {
        guard engine.canTrigger(door) else { return }
        firedThisPress = true
        holdTask?.cancel()
        fireBump += 1
        startRipple()
        Task { await engine.trigger(door) }
    }

    private func startRipple() {
        rippleEndTask?.cancel()
        rippleStart = Date()
        rippleAckAt = nil
        rippleStopEmit = nil
    }

    /// The send finished: rings from now on take the result colour. Keep emitting
    /// until at least one result-coloured ring is out (and a full ripple overall),
    /// then stop emitting and let the rings in flight finish before removing it.
    private func ackRipple(_ outcomePhase: GarageEngine.Phase) {
        guard let start = rippleStart, rippleAckAt == nil else { return }
        let now = Date()
        rippleAckAt = now
        rippleAckTint = GarageStyle.tint(outcomePhase, online: door.online)
        let stopEmit = max(start.addingTimeInterval(RippleRings.minimumDuration),
                           now.addingTimeInterval(RippleRings.spacing + 0.02))
        rippleStopEmit = stopEmit
        rippleEndTask?.cancel()
        rippleEndTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(stopEmit.timeIntervalSinceNow + RippleRings.period))
            guard !Task.isCancelled else { return }
            rippleStart = nil
        }
    }

    private func phaseChanged(_ new: GarageEngine.Phase) {
        if new != .sending { ackRipple(new) }
        switch new {
        case .sending:
            withAnimation(.smooth(duration: 0.3)) { holdProgress = 0 }
            if rippleStart == nil { startRipple() } // e.g. a press-again
        case .moving:
            ackBump += 1
        case .finished(let outcome):
            switch outcome {
            case .done, .sent:
                successBump += 1
                burst += 1
            case .unknown:
                warnBump += 1
            default:
                errorBump += 1
            }
        case .pressedAgain:
            successBump += 1
        case .idle:
            break
        }
    }
}

/// Rings rippling outward from the dial's edge — a radio broadcast leaving the
/// button. A new ring is emitted every `spacing` seconds and spreads for
/// `period`. Each ring keeps the colour of the moment it was emitted: `sendTint`
/// before the ack, `ackTint` after — so the cyan rings show the real wait.
private struct RippleRings: View {
    let start: Date
    let sendTint: Color
    let ackAt: Date?
    let ackTint: Color
    let stopEmitAt: Date?

    static let period: Double = 1.2
    static let spacing: Double = period / 3
    /// At least one full ripple is always shown, even if the ack is instant.
    static let minimumDuration: Double = 1.2

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60)) { ctx in
            let elapsed = ctx.date.timeIntervalSince(start)
            // Rings currently alive: emitted within the last `period`.
            let newest = Int((elapsed / Self.spacing).rounded(.down))
            let oldest = max(0, newest - Int((Self.period / Self.spacing).rounded(.up)))
            ZStack {
                ForEach(oldest...max(oldest, newest), id: \.self) { k in
                    let emitted = start.addingTimeInterval(Double(k) * Self.spacing)
                    let age = ctx.date.timeIntervalSince(emitted)
                    if age >= 0, age < Self.period, stopEmitAt.map({ emitted < $0 }) ?? true {
                        let p = age / Self.period
                        let tint = (ackAt.map { emitted >= $0 } ?? false) ? ackTint : sendTint
                        Circle()
                            .stroke(tint, lineWidth: 2.5 * (1 - p) + 0.5)
                            .scaleEffect(1 + 0.55 * p)
                            .opacity(0.75 * (1 - p))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct Burst {
    var scale: CGFloat = 1
    var opacity: Double = 0
}

/// Hold-to-fire (with press tracking) or plain tap, chosen by config.
private struct TriggerGesture: ViewModifier {
    let hold: Bool
    let duration: Double
    let holdCompleted: () -> Void
    let tapped: () -> Void
    let pressingChanged: (Bool) -> Void

    func body(content: Content) -> some View {
        if hold {
            content.onLongPressGesture(minimumDuration: duration, maximumDistance: 44,
                                       perform: holdCompleted, onPressingChanged: pressingChanged)
        } else {
            content.onTapGesture(perform: tapped)
        }
    }
}

/// Symbols, tints and copy per phase — one place to tune the look.
enum GarageStyle {
    static func symbol(_ phase: GarageEngine.Phase) -> String {
        switch phase {
        case .idle, .sending, .moving: "door.garage.closed"
        case .pressedAgain: "checkmark"
        case .finished(let o):
            switch o {
            case .done, .sent: "checkmark"
            case .offline: "wifi.slash"
            case .slowDown: "hourglass"
            case .denied: "lock.fill"
            case .unknown: "questionmark.circle"
            case .refused, .failed: "exclamationmark.triangle.fill"
            }
        }
    }

    static func tint(_ phase: GarageEngine.Phase, online: Bool) -> Color {
        switch phase {
        case .idle: online ? .cyan : .gray
        case .sending, .moving: .cyan
        case .pressedAgain: .green
        case .finished(let o):
            switch o {
            case .done, .sent: .green
            case .offline, .unknown: .orange
            case .slowDown: .yellow
            case .denied, .refused, .failed: .red
            }
        }
    }

    static func status(_ phase: GarageEngine.Phase, online: Bool, hold: Bool,
                       appearance: GarageAppearance = .standard) -> String {
        switch phase {
        case .idle:
            if !online { return "Opener offline" }
            return hold ? appearance.holdPrompt : appearance.tapPrompt
        case .sending: return "Sending…"
        case .moving: return "Door moving…"
        case .pressedAgain: return "Pressed"
        case .finished(let o):
            switch o {
            case .done: return "Done"
            case .sent: return "Sent"
            case .offline: return "The opener isn't connected"
            case .slowDown: return "Too many presses — give it a moment"
            case .denied: return "No access"
            case .unknown(let m), .refused(let m), .failed(let m): return m
            }
        }
    }
}
