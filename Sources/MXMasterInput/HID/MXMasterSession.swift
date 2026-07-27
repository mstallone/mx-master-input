import Foundation

final class MXMasterSession: @unchecked Sendable {
    private final class PendingRequest {
        let featureIndex: UInt8
        let function: UInt8
        let semaphore = DispatchSemaphore(value: 0)
        var response: HIDPPPacket?

        init(featureIndex: UInt8, function: UInt8) {
            self.featureIndex = featureIndex
            self.function = function
        }
    }

    private enum Feature {
        static let root: UInt16 = 0x0000
        static let deviceName: UInt16 = 0x0005
        static let reprogrammableControlsV4: UInt16 = 0x1B04
        static let haptic: UInt16 = 0x19B0
    }

    private let workQueue = DispatchQueue(
        label: "com.mattstallone.mxmasterinput.session",
        qos: .userInteractive
    )
    private let pendingLock = NSLock()
    private let recognizer: ContinuousGestureRecognizer

    private var connection: MXHIDConnection?
    private var pendingRequest: PendingRequest?
    private var eventHandler: (@Sendable (MXMasterEvent) -> Void)?
    private var gestureHandler: (@Sendable (PanelGestureEvent) -> Void)?
    private var tapHandler: (@Sendable () -> Void)?

    private var deviceIndex: UInt8 = 0
    private var reprogrammableControlsIndex: UInt8?
    private var hapticIndex: UInt8?
    private var panelHeld = false
    private var panelDiverted = false
    private var started = false

    init(
        gestureThreshold: Double = 30,
        horizontalDeadZone: Double = 12,
        motionActivationDelay: TimeInterval = 0.06,
        maximumTapDuration: TimeInterval = 0.4,
        isMissionControlActive: @escaping () -> Bool = {
            MXIsMissionControlActive()
        }
    ) {
        recognizer = ContinuousGestureRecognizer(
            activationThreshold: gestureThreshold,
            horizontalDeadZone: horizontalDeadZone,
            motionActivationDelay: motionActivationDelay,
            maximumTapDuration: maximumTapDuration,
            allowsDownwardGesture: isMissionControlActive
        )
    }

    func start(
        activeMode: Bool,
        eventHandler: @escaping @Sendable (MXMasterEvent) -> Void,
        gestureHandler: @escaping @Sendable (PanelGestureEvent) -> Void,
        tapHandler: @escaping @Sendable () -> Void
    ) async throws -> ConnectedMXMaster {
        try await withCheckedThrowingContinuation { continuation in
            workQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: MXMasterSessionError.stopped)
                    return
                }

                do {
                    if self.started {
                        self.stopOnQueue()
                    }
                    self.eventHandler = eventHandler
                    self.gestureHandler = gestureHandler
                    self.tapHandler = tapHandler
                    let device = try self.connectOnQueue(activeMode: activeMode)
                    self.started = true
                    continuation.resume(returning: device)
                } catch {
                    self.stopOnQueue()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            workQueue.async { [weak self] in
                self?.stopOnQueue()
                continuation.resume()
            }
        }
    }

    func stopSynchronously() {
        workQueue.sync {
            stopOnQueue()
        }
    }

    private func connectOnQueue(activeMode: Bool) throws -> ConnectedMXMaster {
        emit(.status("Searching for the Logitech HID++ interface…"))

        let candidates = MXHIDConnection.logitechVendorDevices()
        guard !candidates.isEmpty else {
            throw MXMasterSessionError.noVendorInterface
        }

        var lastOpenError: String?

        for candidate in candidates {
            let candidateConnection = MXHIDConnection(deviceInfo: candidate)
            do {
                try candidateConnection.open { [weak self] report in
                    self?.receive(report)
                }
            } catch {
                lastOpenError = error.localizedDescription
                continue
            }

            connection = candidateConnection
            let indexes: [UInt8]
            if candidate.productID == 0xC548 {
                indexes = Array(1 ... 6)
            } else {
                indexes = [0xFF, 1, 2, 3, 4, 5, 6]
            }

            for index in indexes {
                deviceIndex = index
                guard let reprogIndex = findFeature(
                    Feature.reprogrammableControlsV4,
                    timeout: 0.4
                ) else {
                    continue
                }

                reprogrammableControlsIndex = reprogIndex
                let name = queryDeviceName() ?? ""
                guard name.localizedCaseInsensitiveContains("MX Master 4") else {
                    reprogrammableControlsIndex = nil
                    continue
                }

                emit(.status("Reading \(name) controls…"))
                let controls = discoverControls()
                guard let panel = controls.first(where: {
                    $0.controlID == MXMasterProtocol.sensePanelControlID
                }), panel.isDivertable else {
                    throw MXMasterSessionError.missingSensePanel
                }

                hapticIndex = findFeature(Feature.haptic, timeout: 0.8)
                var hapticDisabled = false

                if activeMode {
                    guard let hapticIndex else {
                        throw MXMasterSessionError.missingHapticFeature
                    }

                    // The device rejects [0x00, 0x00]. It requires a retained
                    // intensity while the enabled bit is clear.
                    hapticDisabled = request(
                        featureIndex: hapticIndex,
                        function: 2,
                        parameters: MXMasterProtocol.hapticOffParameters,
                        timeout: 1.0
                    ) != nil
                    guard hapticDisabled else {
                        throw MXMasterSessionError.hapticDisableFailed
                    }
                }

                if activeMode {
                    guard setPanelReporting(
                        flags: MXMasterProtocol.divertPanelWithRawXY,
                        timeout: 1.0
                    ) else {
                        throw MXMasterSessionError.panelDiversionFailed
                    }
                    panelDiverted = true
                }

                let connected = ConnectedMXMaster(
                    name: name,
                    transport: candidate.transport,
                    receiverProductID: candidate.productID,
                    deviceIndex: index,
                    controls: controls,
                    hapticSupported: hapticIndex != nil,
                    hapticDisabled: hapticDisabled,
                    panelDiverted: panelDiverted
                )
                emit(.connected(connected))
                return connected
            }

            candidateConnection.close()
            connection = nil
            reprogrammableControlsIndex = nil
            hapticIndex = nil
        }

        if let lastOpenError {
            throw MXMasterSessionError.unableToOpen(lastOpenError)
        }
        throw MXMasterSessionError.noMXMaster4
    }

    private func stopOnQueue() {
        if panelDiverted {
            _ = setPanelReporting(
                flags: MXMasterProtocol.restorePanelRawXYDefault,
                timeout: 0.5
            )
        }

        panelDiverted = false
        panelHeld = false
        if recognizer.cancel() {
            gestureHandler?(.cancelled)
        }

        pendingLock.lock()
        let pending = pendingRequest
        pendingRequest = nil
        pendingLock.unlock()
        pending?.semaphore.signal()

        connection?.close()
        connection = nil
        reprogrammableControlsIndex = nil
        hapticIndex = nil
        started = false
        emit(.disconnected)
    }

    private func findFeature(
        _ featureID: UInt16,
        timeout: TimeInterval
    ) -> UInt8? {
        let response = request(
            featureIndex: 0,
            function: 0,
            parameters: [
                UInt8((featureID >> 8) & 0xFF),
                UInt8(featureID & 0xFF),
                0,
            ],
            timeout: timeout
        )
        guard let index = response?.parameters.first, index != 0 else {
            return nil
        }
        return index
    }

    private func queryDeviceName() -> String? {
        guard let featureIndex = findFeature(
            Feature.deviceName,
            timeout: 0.8
        ) else {
            return nil
        }

        guard let lengthResponse = request(
            featureIndex: featureIndex,
            function: 0,
            parameters: [0, 0, 0],
            timeout: 0.8
        ), let lengthByte = lengthResponse.parameters.first else {
            return nil
        }

        let nameLength = Int(lengthByte)
        guard nameLength > 0 else {
            return nil
        }

        var nameBytes: [UInt8] = []
        var offset = 0
        while offset < nameLength {
            guard let response = request(
                featureIndex: featureIndex,
                function: 1,
                parameters: [UInt8(clamping: offset), 0, 0],
                timeout: 0.8
            ) else {
                break
            }

            let remaining = nameLength - offset
            let chunk = Array(response.parameters.prefix(remaining))
            guard !chunk.isEmpty else {
                break
            }
            nameBytes.append(contentsOf: chunk)
            offset += chunk.count
        }

        return String(bytes: nameBytes.prefix(nameLength), encoding: .ascii)?
            .trimmingCharacters(in: .controlCharacters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func discoverControls() -> [ReprogrammableControl] {
        guard let featureIndex = reprogrammableControlsIndex,
              let countResponse = request(
                  featureIndex: featureIndex,
                  function: 0,
                  parameters: [],
                  timeout: 0.8
              ),
              let countByte = countResponse.parameters.first else {
            return []
        }

        let count = min(Int(countByte), 32)
        var controls: [ReprogrammableControl] = []
        controls.reserveCapacity(count)

        for index in 0 ..< count {
            guard let response = request(
                featureIndex: featureIndex,
                function: 1,
                parameters: [UInt8(index)],
                timeout: 0.5
            ), response.parameters.count >= 9 else {
                continue
            }

            let bytes = response.parameters
            controls.append(
                ReprogrammableControl(
                    index: UInt8(index),
                    controlID: UInt16(bytes[0]) << 8 | UInt16(bytes[1]),
                    taskID: UInt16(bytes[2]) << 8 | UInt16(bytes[3]),
                    flags: UInt16(bytes[4]) | UInt16(bytes[8]) << 8,
                    position: bytes[5],
                    group: bytes[6],
                    groupMask: bytes[7]
                )
            )
        }
        return controls
    }

    private func setPanelReporting(
        flags: UInt8,
        timeout: TimeInterval
    ) -> Bool {
        guard let featureIndex = reprogrammableControlsIndex else {
            return false
        }

        return request(
            featureIndex: featureIndex,
            function: 3,
            parameters: [
                UInt8((MXMasterProtocol.sensePanelControlID >> 8) & 0xFF),
                UInt8(MXMasterProtocol.sensePanelControlID & 0xFF),
                flags,
                0,
                0,
            ],
            timeout: timeout
        ) != nil
    }

    private func request(
        featureIndex: UInt8,
        function: UInt8,
        parameters: [UInt8],
        timeout: TimeInterval
    ) -> HIDPPPacket? {
        guard let connection else {
            return nil
        }

        let pending = PendingRequest(
            featureIndex: featureIndex,
            function: function
        )

        pendingLock.lock()
        guard pendingRequest == nil else {
            pendingLock.unlock()
            return nil
        }
        pendingRequest = pending
        pendingLock.unlock()

        do {
            let report = HIDPPPacket.request(
                deviceIndex: deviceIndex,
                featureIndex: featureIndex,
                function: function,
                parameters: parameters
            )
            try connection.sendOutputReport(report)
        } catch {
            pendingLock.lock()
            if pendingRequest === pending {
                pendingRequest = nil
            }
            pendingLock.unlock()
            emit(.error(error.localizedDescription))
            return nil
        }

        let waitResult = pending.semaphore.wait(
            timeout: .now() + timeout
        )

        pendingLock.lock()
        let response = pending.response
        if pendingRequest === pending {
            pendingRequest = nil
        }
        pendingLock.unlock()

        guard waitResult == .success,
              let response,
              !response.isError else {
            return nil
        }
        return response
    }

    private func receive(_ data: Data) {
        guard let packet = HIDPPPacket.parse(data) else {
            return
        }

        pendingLock.lock()
        let pending = pendingRequest
        let expectedFunctions: Set<UInt8>
        if let pending {
            expectedFunctions = [
                pending.function,
                (pending.function + 1) & 0x0F,
            ]
        } else {
            expectedFunctions = []
        }

        let matchesError =
            packet.isError
            && packet.deviceIndex == deviceIndex
            && packet.parameters.first.map {
                $0 & 0x0F == HIDPPPacket.softwareID
            } == true

        let matchesPending =
            pending != nil
            && (
                matchesError
                || (
                    packet.deviceIndex == self.deviceIndex
                    &&
                    packet.featureIndex == pending?.featureIndex
                    && packet.softwareID == HIDPPPacket.softwareID
                    && expectedFunctions.contains(packet.function)
                )
            )

        if matchesPending, let pending {
            pending.response = packet
            pendingLock.unlock()
            pending.semaphore.signal()
            return
        }
        pendingLock.unlock()

        workQueue.async { [weak self] in
            self?.processUnsolicited(packet)
        }
    }

    private func processUnsolicited(_ packet: HIDPPPacket) {
        guard packet.featureIndex == reprogrammableControlsIndex else {
            return
        }

        if packet.function == 1 {
            guard panelHeld, packet.parameters.count >= 4 else {
                return
            }

            let dx = decodeSigned16(
                high: packet.parameters[0],
                low: packet.parameters[1]
            )
            let dy = decodeSigned16(
                high: packet.parameters[2],
                low: packet.parameters[3]
            )
            guard dx != 0 || dy != 0 else {
                return
            }

            if let update = recognizer.ingest(dx: dx, dy: dy) {
                emit(.direction(update.direction))
                switch update.phase {
                case .began:
                    gestureHandler?(
                        .began(axis: update.axis, delta: update.delta)
                    )
                case .changed:
                    gestureHandler?(.changed(delta: update.delta))
                }
            }
            return
        }

        guard packet.function == 0 else {
            return
        }

        var heldControlIDs = Set<UInt16>()
        var index = 0
        while index + 1 < packet.parameters.count {
            let controlID =
                UInt16(packet.parameters[index]) << 8
                | UInt16(packet.parameters[index + 1])
            if controlID == 0 {
                break
            }
            heldControlIDs.insert(controlID)
            index += 2
        }

        let panelNowHeld = heldControlIDs.contains(
            MXMasterProtocol.sensePanelControlID
        )
        if panelNowHeld, !panelHeld {
            panelHeld = true
            recognizer.begin()
            emit(.panelDown)
        } else if !panelNowHeld, panelHeld {
            panelHeld = false
            let end = recognizer.end()
            emit(.panelUp)
            if end.didBeginSwipe {
                gestureHandler?(.ended)
            } else if end.isTap {
                emit(.tap)
                tapHandler?()
            }
        }
    }

    private func decodeSigned16(high: UInt8, low: UInt8) -> Int {
        let unsigned = UInt16(high) << 8 | UInt16(low)
        return Int(Int16(bitPattern: unsigned))
    }

    private func emit(_ event: MXMasterEvent) {
        eventHandler?(event)
    }
}
