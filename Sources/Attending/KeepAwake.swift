import AppKit
import IOKit.pwr_mgt

/// Keeps the Mac awake: by hand from the coffee cup (screen stays on), and on its own
/// while an agent works (the screen may sleep, the Mac doesn't).
@MainActor final class KeepAwake: ObservableObject {
    /// When the manual keep-awake ends; `.distantFuture` for until turned off.
    @Published private(set) var manualUntil: Date?
    @Published var withAgents = UserDefaults.standard.object(forKey: "awakeWithAgents") as? Bool ?? true {
        didSet { UserDefaults.standard.set(withAgents, forKey: "awakeWithAgents"); update() }
    }
    var agentsWorking = false { didSet { if agentsWorking != oldValue { update() } } }
    var manual: Bool { (manualUntil ?? .distantPast) > Date() }
    var active: Bool { manual || (withAgents && agentsWorking) }

    private var displayAssertion: IOPMAssertionID = 0
    private var systemAssertion: IOPMAssertionID = 0
    private var expiry: Task<Void, Never>?

    /// Turns the manual keep-awake on for `minutes` (nil: until turned off), or off.
    func set(minutes: Int?, on: Bool = true) {
        expiry?.cancel()
        manualUntil = on ? (minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) } ?? .distantFuture) : nil
        if on, let minutes {
            expiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(minutes * 60))
                guard !Task.isCancelled else { return }
                self?.manualUntil = nil; self?.update()
            }
        }
        update()
    }
    func toggle() { set(minutes: nil, on: !manual) }

    private func update() {
        let wantDisplay = manual, wantSystem = active
        assert(&displayAssertion, wanted: wantDisplay, type: kIOPMAssertionTypePreventUserIdleDisplaySleep, reason: "Keep awake (Attending)")
        assert(&systemAssertion, wanted: wantSystem, type: kIOPMAssertionTypePreventUserIdleSystemSleep, reason: "An agent is working (Attending)")
        objectWillChange.send()
    }
    private func assert(_ id: inout IOPMAssertionID, wanted: Bool, type: String, reason: String) {
        if wanted && id == 0 {
            IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        } else if !wanted && id != 0 {
            IOPMAssertionRelease(id); id = 0
        }
    }
}
