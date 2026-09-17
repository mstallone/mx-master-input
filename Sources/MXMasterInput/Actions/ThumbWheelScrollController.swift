import CoreGraphics
import Foundation

/// HID++ 0x2150 reports rotation separately from touch/proximity changes.
struct ThumbWheelReport: Equatable {
    enum State: UInt8 {
        case inactive = 0, began = 1, changed = 2, ended = 3
    }

    let delta: Int
    let state: State

    init?(packet: HIDPPPacket, deviceIndex: UInt8, featureIndex: UInt8) {
        guard packet.deviceIndex == deviceIndex,
              packet.featureIndex == featureIndex,
              packet.softwareID == 0, packet.function == 0,
              packet.parameters.count >= 6,
              let state = State(rawValue: packet.parameters[4]) else {
            return nil
        }
        delta = Int(Int16(bitPattern:
            UInt16(packet.parameters[0]) << 8 | UInt16(packet.parameters[1])
        ))
        self.state = state
    }
}

/// Confined to the HID session queue, including its idle watchdog.
final class ThumbWheelScrollController: @unchecked Sendable {
    enum Phase: Int64 {
        case began = 1, changed = 2, ended = 4, cancelled = 8
    }

    private let queue: DispatchQueue?
    private let smoothingFrames: Int
    private var timer: DispatchSourceTimer?
    private var pendingFrames: [Double] = []
    private var pixelRemainder = 0.0
    private var ending = false
    private var beganPosted = false
    private let post: (CGEvent) -> Void
    private let naturalScrolling: () -> Bool
    private var location: CGPoint?
    private var direction = 1.0
    var pixelsPerUnit = 10.0
    var deviceDirection = 1.0
    var isActive: Bool { location != nil }

    init(
        queue: DispatchQueue? = nil,
        smoothingFrames: Int = 4,
        naturalScrolling: @escaping () -> Bool = {
            (UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection")
                as? Bool) ?? true
        },
        post: @escaping (CGEvent) -> Void = { $0.post(tap: .cgSessionEventTap) }
    ) {
        precondition(smoothingFrames > 0)
        self.queue = queue
        self.smoothingFrames = smoothingFrames
        self.naturalScrolling = naturalScrolling
        self.post = post
    }

    func consume(_ report: ThumbWheelReport) {
        if report.state == .began, isActive {
            flushPendingFrames()
            finish()
        }
        if report.delta != 0 {
            ending = false
            if !isActive {
                location = CGEvent(source: nil)?.location ?? .zero
                // Normalize firmware direction, then freeze the user's scroll
                // preference until this gesture ends.
                direction = deviceDirection * (naturalScrolling() ? -1 : 1)
            }
            let delta = Double(report.delta) * pixelsPerUnit * direction
            // Do not let buffered movement delay a physical reversal.
            if pendingFrames.reduce(0, +) * delta < 0 {
                flushPendingFrames()
            }
            let exactPixels = delta + pixelRemainder
            let pixels = exactPixels.rounded()
            pixelRemainder = exactPixels - pixels
            while pendingFrames.count < smoothingFrames { pendingFrames.append(0) }
            // Integer pixel slices preserve the total distance without rounding
            // away small wheel movements at each animation frame.
            for index in 0 ..< smoothingFrames {
                pendingFrames[index] += (pixels * Double(index + 1) / Double(smoothingFrames)).rounded()
                    - (pixels * Double(index) / Double(smoothingFrames)).rounded()
            }
            if !beganPosted { advanceFrame() }
            startTimerIfNeeded()
        }
        if report.state == .ended || report.state == .inactive {
            finish()
        }
    }

    func finish(cancelled: Bool = false) {
        guard isActive else { return }
        if !cancelled, !pendingFrames.isEmpty {
            ending = true
            return
        }
        if beganPosted { send(delta: 0, phase: cancelled ? .cancelled : .ended) }
        timer?.cancel()
        timer = nil
        pendingFrames.removeAll()
        location = nil
        beganPosted = false
        ending = false
        pixelRemainder = 0
    }

    /// Also used by deterministic tests; production calls this at 120 Hz.
    func advanceFrame() {
        if !pendingFrames.isEmpty {
            let delta = pendingFrames.removeFirst()
            if delta != 0 {
                send(delta: delta, phase: beganPosted ? .changed : .began)
                beganPosted = true
            }
        }
        if pendingFrames.isEmpty {
            timer?.cancel()
            timer = nil
            if ending { finish() }
        }
    }

    private func flushPendingFrames() {
        while !pendingFrames.isEmpty { advanceFrame() }
    }

    private func startTimerIfNeeded() {
        guard timer == nil, !pendingFrames.isEmpty, let queue else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0 / 120, repeating: 1.0 / 120,
                       leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.advanceFrame() }
        self.timer = timer
        timer.resume()
    }

    private func send(delta: Double, phase: Phase) {
        guard let event = Self.makeEvent(delta: delta, phase: phase) else { return }
        if let location { event.location = location }
        event.flags = CGEvent(source: nil)?.flags ?? []
        post(event)
    }

    static func makeEvent(delta: Double, phase: Phase) -> CGEvent? {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
            wheel1: 0, wheel2: Int32(delta.rounded()), wheel3: 0
        ) else { return nil }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: delta)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: delta)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        return event
    }
}
