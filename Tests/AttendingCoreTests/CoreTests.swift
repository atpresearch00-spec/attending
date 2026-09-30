import Foundation
import CoreGraphics

import AttendingCore
func XCTAssertTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) { precondition(value, "Expected true", file: file, line: line) }
func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T, file: StaticString = #file, line: UInt = #line) { precondition(lhs == rhs, "Expected equality: \(lhs) != \(rhs)", file: file, line: line) }
func XCTFail(_ message: String, file: StaticString = #file, line: UInt = #line) { preconditionFailure(message, file: file, line: line) }
@main struct CoreTests {
    static func main() async throws {
        let suite = CoreTests()
        try suite.testExecutableDiscovery()
        suite.testOldEventsStayDisconnected()
        suite.testLifecycleAndProjectIdentity()
        suite.testRejectsInvalidAndOutOfOrderEvents()
        suite.testHistoryIsBounded()
        suite.testNotchAndExternalDisplayGeometry()
        try await suite.testPersistenceAndUnsupportedVersion()
        suite.testPrayerTimesMatchReference()
        print("PASS: 8 core checks (lifecycle, validation, bounds, geometry, persistence, prayer times)")
    }
    func testExecutableDiscovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing").path
        let binary = root.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: binary.path)
        XCTAssertEqual(CodexTransport.discoverExecutable(candidates: [missing, binary.path]), nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        XCTAssertEqual(CodexTransport.discoverExecutable(candidates: [missing, binary.path]), binary)
    }
    func testOldEventsStayDisconnected() {
        let launch = Date()
        var state = AppState()
        state.apply(.init(provider: .claudeCode, sessionID: "old", projectPath: "/work", kind: .working, timestamp: launch.addingTimeInterval(-3600)), liveEventsSince: launch)
        XCTAssertEqual(state.sessions.first?.status, .stale)
        state.apply(.init(provider: .claudeCode, sessionID: "old", projectPath: "/work", kind: .working, timestamp: launch), liveEventsSince: launch)
        XCTAssertEqual(state.sessions.first?.status, .working)
        state.apply(.init(provider: .claudeCode, sessionID: "done", projectPath: "/work", kind: .completed, timestamp: launch.addingTimeInterval(-1800)), liveEventsSince: launch)
        XCTAssertEqual(state.sessions.first?.status, .completed)
    }
    func testLifecycleAndProjectIdentity() {
        var state = AppState()
        let start = Date().addingTimeInterval(-20)
        state.apply(.init(provider: .claudeCode, sessionID: "one", projectPath: "/work/Attending", kind: .started, timestamp: start))
        state.apply(.init(provider: .claudeCode, sessionID: "one", projectPath: "/work/Attending", kind: .working, timestamp: start.addingTimeInterval(1)))
        state.apply(.init(provider: .codex, sessionID: "one", projectPath: "/work/Attending", kind: .working, timestamp: start.addingTimeInterval(2)))
        XCTAssertEqual(state.sessions.count, 2)
        XCTAssertEqual(state.projects.count, 1)
        state.apply(.init(provider: .claudeCode, sessionID: "one", projectPath: "/work/Attending", kind: .attention, timestamp: start.addingTimeInterval(3)))
        XCTAssertEqual(state.sessions.first?.status, .attention)
        state.apply(.init(provider: .claudeCode, sessionID: "one", projectPath: "/work/Attending", kind: .completed, timestamp: start.addingTimeInterval(4)))
        XCTAssertEqual(state.sessions.first?.status, .completed)
        state.markDisconnected()
        XCTAssertEqual(state.sessions.first?.status, .completed)
        XCTAssertEqual(state.sessions.last?.status, .stale)
    }
    func testRejectsInvalidAndOutOfOrderEvents() {
        var state = AppState()
        state.apply(.init(provider: .claudeCode, sessionID: "", projectPath: "relative", kind: .working))
        XCTAssertTrue(state.sessions.isEmpty)
        let now = Date()
        state.apply(.init(provider: .claudeCode, sessionID: "one", projectPath: "/work", kind: .completed, timestamp: now))
        state.apply(.init(provider: .claudeCode, sessionID: "one", projectPath: "/work", kind: .working, timestamp: now.addingTimeInterval(-1)))
        XCTAssertEqual(state.sessions.first?.status, .completed)
        state.apply(.init(provider: .claudeCode, sessionID: "two", projectPath: "/work", kind: .working, timestamp: now.addingTimeInterval(120)))
        XCTAssertEqual(state.sessions.count, 1)
    }
    func testHistoryIsBounded() {
        var state = AppState()
        for i in 0..<250 { state.apply(.init(provider: .claudeCode, sessionID: "\(i)", projectPath: "/work", kind: .started)) }
        XCTAssertEqual(state.sessions.count, 200)
    }
    func testNotchAndExternalDisplayGeometry() {
        // Offset origin: a notched laptop screen left of a primary external display.
        let screen = CGRect(x: -1728, y: 400, width: 1728, height: 1117)
        let visible = CGRect(x: -1728, y: 440, width: 1728, height: 1040)
        let notched = NotchMetrics(screen: screen, visible: visible, notchLeft: -964, notchRight: -764, height: 37)
        XCTAssertTrue(notched.hasNotch)
        XCTAssertEqual(notched.center, -864)
        let collapsed = IslandGeometry.collapsed(notched, wing: 40)
        // Symmetric wings: centered on the notch, flush with the top edge.
        XCTAssertEqual(collapsed.midX, -864)
        XCTAssertEqual(collapsed.width, 200 + 2 * (40 + IslandGeometry.ear))
        XCTAssertEqual(collapsed.maxY, screen.maxY)
        XCTAssertEqual(collapsed.minY, screen.maxY - 37)
        // A half-point notch height (37.5 on 14/15-inch panels) stays pixel-exact.
        let half = IslandGeometry.collapsed(NotchMetrics(screen: screen, visible: visible, notchLeft: -964, notchRight: -764, height: 37.5), wing: 40)
        XCTAssertEqual(half.height, 37.5)
        XCTAssertTrue(screen.contains(collapsed))
        for size in [CGSize(width: 640, height: 480), CGSize(width: 420, height: 160)] {
            let panel = IslandGeometry.panel(notched, size: size)
            XCTAssertEqual(panel.maxY, screen.maxY)
            XCTAssertEqual(panel.midX, -864)
            XCTAssertTrue(screen.contains(panel))
        }
        // Oversized requests and notches near an edge stay on screen.
        XCTAssertTrue(screen.contains(IslandGeometry.panel(notched, size: CGSize(width: 4000, height: 4000))))
        let edge = NotchMetrics(screen: screen, visible: visible, notchLeft: screen.maxX - 150, notchRight: screen.maxX - 20, height: 37)
        XCTAssertTrue(screen.contains(IslandGeometry.collapsed(edge, wing: 60)))
        // Missing or implausible notch measurements fall back below the menu bar.
        for broken in [NotchMetrics(screen: screen, visible: visible, notchLeft: nil, notchRight: nil, height: 0),
                       NotchMetrics(screen: screen, visible: visible, notchLeft: -764, notchRight: -964, height: 37),
                       NotchMetrics(screen: screen, visible: visible, notchLeft: -964, notchRight: -764, height: 4)] {
            XCTAssertTrue(!broken.hasNotch)
            let pill = IslandGeometry.collapsed(broken, wing: 40)
            XCTAssertTrue(visible.contains(pill))
            XCTAssertEqual(pill.maxY, visible.maxY - 4)
            let panel = IslandGeometry.panel(broken, size: CGSize(width: 640, height: 480))
            XCTAssertEqual(panel.maxY, visible.maxY - 6)
            XCTAssertTrue(visible.contains(panel))
        }
    }
    func testPersistenceAndUnsupportedVersion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state.json")
        let store = StateStore(url: url)
        var state = AppState()
        state.apply(.init(provider: .claudeCode, sessionID: "one", projectPath: "/work", kind: .working))
        try await store.save(state)
        let restored = try await store.load()
        XCTAssertEqual(restored, state)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        try Data("{\"version\":99,\"sessions\":[]}".utf8).write(to: url)
        do { _ = try await store.load(); XCTFail("Accepted an unsupported schema") } catch StorageError.unsupportedVersion(99) { }
    }

    /// Reference times from api.aladhan.com for the same places, dates and methods.
    /// Allows one minute for rounding differences.
    func testPrayerTimesMatchReference() {
        func check(_ date: String, _ lat: Double, _ lon: Double, _ zone: String, _ method: PrayerTimes.Method, _ asr: PrayerTimes.Asr, _ expected: [String]) {
            let tz = TimeZone(identifier: zone)!
            let parser = DateFormatter(); parser.timeZone = tz; parser.dateFormat = "yyyy-MM-dd HH:mm"
            let noon = parser.date(from: "\(date) 12:00")!
            let times = PrayerTimes.times(on: noon, latitude: lat, longitude: lon, timeZone: tz, method: method, asr: asr)
            for (prayer, text) in zip([PrayerTimes.Prayer.fajr, .sunrise, .dhuhr, .asr, .maghrib, .isha], expected) {
                let want = parser.date(from: "\(date) \(text)")!
                let got = times[prayer]!
                if abs(got.timeIntervalSince(want)) > 60 { XCTFail("\(prayer) on \(date) at \(lat),\(lon): got \(parser.string(from: got)), expected \(text)") }
            }
        }
        // Gulf coast of Florida (27.50° N, 82.57° W).
        check("2026-09-29", 27.50, -82.57, "America/New_York", .isna, .standard, ["06:18", "07:22", "13:21", "16:45", "19:19", "20:22"])
        check("2026-09-29", 27.50, -82.57, "America/New_York", .mwl, .standard, ["06:05", "07:22", "13:21", "16:45", "19:19", "20:32"])
        check("2026-09-29", 27.50, -82.57, "America/New_York", .ummAlQura, .standard, ["06:02", "07:22", "13:21", "16:45", "19:19", "20:49"])
        // London in winter, Hanafi Asr.
        check("2027-01-15", 51.51, -0.13, "Europe/London", .mwl, .hanafi, ["05:59", "08:00", "12:10", "14:32", "16:21", "18:14"])
    }
}
