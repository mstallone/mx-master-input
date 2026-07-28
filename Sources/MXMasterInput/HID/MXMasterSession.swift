import Foundation

final class MXMasterSession: @unchecked Sendable {
    private enum PendingResponse {
        case hidpp20(
            deviceIndex: UInt8,
            featureIndex: UInt8,
            function: UInt8
        )
        case receiverRegister(command: UInt8, address: UInt8)
    }

    private final class PendingRequest {
        let expectedResponse: PendingResponse
        let semaphore = DispatchSemaphore(value: 0)
        var response: HIDPPPacket?

        init(expectedResponse: PendingResponse) {
            self.expectedResponse = expectedResponse
        }
    }

    private enum Feature {
        static let root: UInt16 = 0x0000
        static let deviceName: UInt16 = 0x0005
        static let reprogrammableControlsV4: UInt16 = 0x1B04
        static let haptic: UInt16 = 0x19B0
    }

    private enum Receiver {
        static let productID = 0xC548
        static let index: UInt8 = 0xFF
        static let readShortRegister: UInt8 = 0x81
        static let writeShortRegister: UInt8 = 0x80
        static let notificationsRegister: UInt8 = 0x00
        static let wirelessNotificationsFlag: UInt8 = 0x01
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
    private var activeMode = false
    private var started = false
    private var configurationRecoveryGeneration = 0
    private var configurationRecoveryScheduled = false

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
                    self.activeMode = activeMode
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
            if candidate.productID == Receiver.productID {
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

                if activeMode,
                   candidate.productID == Receiver.productID,
                   !enableReceiverWirelessNotifications() {
                    throw MXMasterSessionError.receiverNotificationsFailed
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
        configurationRecoveryGeneration += 1
        configurationRecoveryScheduled = false

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
        activeMode = false
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
        let pending = PendingRequest(
            expectedResponse: .hidpp20(
                deviceIndex: deviceIndex,
                featureIndex: featureIndex,
                function: function
            )
        )
        let report = HIDPPPacket.request(
            deviceIndex: deviceIndex,
            featureIndex: featureIndex,
            function: function,
            parameters: parameters
        )
        guard let response = sendRequest(
            report,
            pending: pending,
            timeout: timeout
        ), !response.isError else {
            return nil
        }
        return response
    }

    private func receiverRegisterRequest(
        command: UInt8,
        parameters: [UInt8],
        timeout: TimeInterval
    ) -> HIDPPPacket? {
        let pending = PendingRequest(
            expectedResponse: .receiverRegister(
                command: command,
                address: Receiver.notificationsRegister
            )
        )
        let report = HIDPPPacket.shortRegisterRequest(
            deviceIndex: Receiver.index,
            command: command,
            address: Receiver.notificationsRegister,
            parameters: parameters
        )
        return sendRequest(report, pending: pending, timeout: timeout)
    }

    private func sendRequest(
        _ report: Data,
        pending: PendingRequest,
        timeout: TimeInterval
    ) -> HIDPPPacket? {
        guard let connection else {
            return nil
        }

        pendingLock.lock()
        guard pendingRequest == nil else {
            pendingLock.unlock()
            return nil
        }
        pendingRequest = pending
        pendingLock.unlock()

        do {
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

        guard waitResult == .success, let response else {
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
        let matchesPending = pending.map {
            matches(packet, expected: $0.expectedResponse)
        } == true

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

    private func matches(
        _ packet: HIDPPPacket,
        expected: PendingResponse
    ) -> Bool {
        switch expected {
        case let .hidpp20(expectedDevice, featureIndex, function):
            let matchesError =
                packet.isError
                && packet.deviceIndex == expectedDevice
                && packet.parameters.first.map {
                    $0 & 0x0F == HIDPPPacket.softwareID
                } == true
            let expectedFunctions: Set<UInt8> = [
                function,
                (function + 1) & 0x0F,
            ]
            return matchesError
                || (
                    packet.deviceIndex == expectedDevice
                    && packet.featureIndex == featureIndex
                    && packet.softwareID == HIDPPPacket.softwareID
                    && expectedFunctions.contains(packet.function)
                )

        case let .receiverRegister(command, address):
            let packetAddress =
                packet.function << 4
                | packet.softwareID
            return packet.deviceIndex == Receiver.index
                && packet.featureIndex == command
                && packetAddress == address
        }
    }

    private func processUnsolicited(_ packet: HIDPPPacket) {
        if packet.deviceIndex == deviceIndex,
           packet.reportsEstablishedLink {
            scheduleConfigurationRecovery()
            return
        }

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

    private func enableReceiverWirelessNotifications() -> Bool {
        guard let response = receiverRegisterRequest(
            command: Receiver.readShortRegister,
            parameters: [],
            timeout: 0.8
        ), response.parameters.count >= 3 else {
            return false
        }

        let originalFlags = Array(response.parameters.prefix(3))
        guard originalFlags[1] & Receiver.wirelessNotificationsFlag == 0 else {
            return true
        }

        var updatedFlags = originalFlags
        updatedFlags[1] |= Receiver.wirelessNotificationsFlag
        guard receiverRegisterRequest(
            command: Receiver.writeShortRegister,
            parameters: updatedFlags,
            timeout: 0.8
        ) != nil,
        let verification = receiverRegisterRequest(
            command: Receiver.readShortRegister,
            parameters: [],
            timeout: 0.8
        ),
        verification.parameters.count >= 3,
        verification.parameters[1] & Receiver.wirelessNotificationsFlag != 0
        else {
            return false
        }

        // Register 0x00 is shared receiver state with no per-client ownership.
        // Leave this additive bit enabled so stopping this session cannot
        // disable notifications that another HID++ client relies on.
        return true
    }

    /// Reprogrammable-control reporting is volatile device state. The mouse
    /// clears it when its wireless link sleeps, while the receiver's HID
    /// connection and this session remain open. Reapply the active-mode
    /// configuration whenever the receiver reports that the mouse woke.
    private func scheduleConfigurationRecovery() {
        guard started, activeMode, !configurationRecoveryScheduled else {
            return
        }

        configurationRecoveryScheduled = true
        configurationRecoveryGeneration += 1
        let generation = configurationRecoveryGeneration

        panelHeld = false
        if recognizer.cancel() {
            gestureHandler?(.cancelled)
        }

        workQueue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.recoverConfiguration(
                generation: generation,
                attempt: 0
            )
        }
    }

    private func recoverConfiguration(
        generation: Int,
        attempt: Int
    ) {
        guard started,
              activeMode,
              configurationRecoveryScheduled,
              generation == configurationRecoveryGeneration else {
            return
        }

        let reprogIndex = findFeature(
            Feature.reprogrammableControlsV4,
            timeout: 0.8
        )
        let recoveredHapticIndex = findFeature(
            Feature.haptic,
            timeout: 0.8
        )
        reprogrammableControlsIndex = reprogIndex
        hapticIndex = recoveredHapticIndex

        let hapticDisabled = recoveredHapticIndex.map {
            request(
                featureIndex: $0,
                function: 2,
                parameters: MXMasterProtocol.hapticOffParameters,
                timeout: 1.0
            ) != nil
        } == true
        let diversionRestored =
            reprogIndex != nil
            && setPanelReporting(
                flags: MXMasterProtocol.divertPanelWithRawXY,
                timeout: 1.0
            )

        if hapticDisabled, diversionRestored {
            panelDiverted = true
            configurationRecoveryScheduled = false
            emit(.status("Enabled"))
            return
        }

        let retryDelays: [TimeInterval] = [0.5, 1.5]
        guard attempt < retryDelays.count else {
            configurationRecoveryScheduled = false
            emit(.error(
                "The mouse woke, but its gesture configuration could not be restored."
            ))
            return
        }

        workQueue.asyncAfter(
            deadline: .now() + retryDelays[attempt]
        ) { [weak self] in
            self?.recoverConfiguration(
                generation: generation,
                attempt: attempt + 1
            )
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
