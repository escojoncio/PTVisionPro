// SPDX-License-Identifier: MIT
//
// The controller, read through Apple's GameController framework with its PlayStation profiles:
// a DualSense (GCDualSenseGamepad) or a DualShock 4 (GCDualShockGamepad); any other gamepad
// while there is none of Sony's. Every change of a stick or button is mapped to the game's
// actions (pt_vp_controller) and handed to whoever listens (GameRunner gives it to the core).
// The other direction - the game's haptic pulses - goes to the same controller's motors through
// CoreHaptics engines on its handles.
//
// PlayStation VR2 Sense controllers (GameController's spatial controllers, one per hand) are a
// controller too: the left one moves, the right one turns, and their face buttons are the four
// of a PlayStation controller. Their position in space is not given by GameController
// (see hand_valid below).

import CoreHaptics
import Foundation
import GameController

final class PlayStationController: @unchecked Sendable {
    static let shared = PlayStationController()

    /// For the launcher: what is connected.
    struct Status: Equatable {
        var name: String
        var kind: Kind
        var isPlayStation: Bool
        /// 0 to 1 when the controller reports it.
        var batteryLevel: Float?
        var isCharging: Bool
    }

    enum Kind: Equatable {
        /// A DualSense or DualShock 4.
        case playStation
        /// PlayStation VR2 Sense controllers.
        case sense
        /// Any other gamepad.
        case other
    }

    /// The haptic engine of one hand of one controller.
    private static func key(_ controller: GCController, _ hand: Int) -> String {
        "\(ObjectIdentifier(controller).hashValue)-\(hand)"
    }

    /// GameController's product category of a PlayStation VR2 Sense controller (the value of
    /// GCProductCategorySpatialController, written out so that the app builds against any SDK).
    private static let spatialCategory = "Spatial Controller"

    private let lock = NSLock()
    private var controller: GCController?
    private var senseLeft: GCController?
    private var senseRight: GCController?
    /// Haptic engines by controller and hand (0 left, 1 right).
    private var pulsers: [String: HapticPulser] = [:]
    private var observers: [NSObjectProtocol] = []
    private var state = pt_vp_controller()
    private let inputQueue = DispatchQueue(label: "pt.controller", qos: .userInteractive)

    /// Every change of the controller, already mapped to the game's actions.
    var onStateChange: ((pt_vp_controller) -> Void)?
    var onStatusChange: ((Status?) -> Void)?

    private init() {}

    /// Starts watching for controllers. On the main thread.
    func start() {
        GCController.shouldMonitorBackgroundEvents = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            self?.choose()
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.choose()
        })
        GCController.startWirelessControllerDiscovery {}
        choose()
    }

    var status: Status? {
        lock.lock()
        defer { lock.unlock() }
        if let controller {
            return Self.describe(controller)
        }
        if senseLeft != nil || senseRight != nil {
            return senseStatus
        }
        return nil
    }

    /// The newest state, for whoever starts listening late.
    var currentState: pt_vp_controller {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    private var senseStatus: Status {
        let count = (senseLeft != nil ? 1 : 0) + (senseRight != nil ? 1 : 0)
        let battery = [senseLeft, senseRight].compactMap { $0?.battery?.batteryLevel }.min()
        return Status(name: L("PlayStation VR2 Sense (\(count) de 2)", "PlayStation VR2 Sense (\(count) of 2)"),
                      kind: .sense, isPlayStation: true, batteryLevel: battery, isCharging: false)
    }

    static func isSense(_ controller: GCController) -> Bool {
        controller.productCategory == spatialCategory
    }

    private static func isPlayStation(_ controller: GCController) -> Bool {
        controller.extendedGamepad is GCDualSenseGamepad || controller.extendedGamepad is GCDualShockGamepad
    }

    private static func describe(_ controller: GCController) -> Status {
        let battery = controller.battery
        return Status(
            name: controller.vendorName ?? controller.productCategory,
            kind: isPlayStation(controller) ? .playStation : .other,
            isPlayStation: isPlayStation(controller),
            batteryLevel: battery.map { $0.batteryLevel },
            isCharging: battery.map { $0.batteryState == .charging || $0.batteryState == .full } ?? false
        )
    }

    /// Whether a Sense controller is the left one, by its name.
    private static func isLeftSense(_ controller: GCController) -> Bool {
        let name = (controller.vendorName ?? "").lowercased()
        return name.contains("left") || name.contains("(l)") || name.hasSuffix(" l")
    }

    /// Picks the controller: a PlayStation one if there is one, then Sense controllers, then
    /// any other gamepad.
    private func choose() {
        let all = GCController.controllers()
        let senses = all.filter(Self.isSense)
        let candidates = all.filter { $0.extendedGamepad != nil && !Self.isSense($0) }
        var chosen = candidates.first(where: Self.isPlayStation)
        var useSense = false
        if chosen == nil && !senses.isEmpty {
            useSense = true
        } else if chosen == nil {
            chosen = candidates.first
        }
        updateSense(useSense ? senses : [])
        lock.lock()
        let previous = controller
        let changed = chosen !== controller
        if changed {
            if let previous {
                previous.extendedGamepad?.valueChangedHandler = nil
                pulsers[Self.key(previous, 0)]?.stop()
                pulsers[Self.key(previous, 1)]?.stop()
                pulsers[Self.key(previous, 0)] = nil
                pulsers[Self.key(previous, 1)] = nil
            }
            controller = chosen
            state = pt_vp_controller()
        }
        lock.unlock()
        if useSense {
            LogFiles.log("Controller: PlayStation VR2 Sense (\(senses.count))")
            publishSense()
            onStatusChange?(senseStatus)
            return
        }
        guard changed else { return }
        if let chosen {
            setUp(chosen)
            let status = Self.describe(chosen)
            LogFiles.log("Controller: \(status.name) (\(chosen.productCategory))")
            publishGamepad(chosen)
            onStatusChange?(status)
        } else {
            LogFiles.log("Controller: none")
            publish(pt_vp_controller())
            onStatusChange?(nil)
        }
    }

    private func setUp(_ controller: GCController) {
        // The PS button, Create and the touchpad belong to the game, not to the system.
        for (_, button) in controller.physicalInputProfile.buttons where button.isBoundToSystemGesture {
            button.preferredSystemGestureState = .disabled
        }
        controller.handlerQueue = inputQueue
        controller.extendedGamepad?.valueChangedHandler = { [weak self] _, _ in
            self?.publishGamepad(controller)
        }
        if let haptics = controller.haptics {
            let localities = haptics.supportedLocalities
            let left: GCHapticsLocality = localities.contains(.leftHandle) ? .leftHandle : .default
            let right: GCHapticsLocality = localities.contains(.rightHandle) ? .rightHandle : .default
            lock.lock()
            pulsers[Self.key(controller, 0)] = HapticPulser(haptics: haptics, locality: left)
            pulsers[Self.key(controller, 1)] = HapticPulser(haptics: haptics, locality: right)
            lock.unlock()
        }
    }

    /// Takes the Sense controllers into use (or none), one for each hand.
    private func updateSense(_ senses: [GCController]) {
        var left: GCController?
        var right: GCController?
        for sense in senses {
            if Self.isLeftSense(sense) {
                if left == nil { left = sense } else if right == nil { right = sense }
            } else {
                if right == nil { right = sense } else if left == nil { left = sense }
            }
        }
        lock.lock()
        let previous = [senseLeft, senseRight].compactMap { $0 }
        senseLeft = left
        senseRight = right
        lock.unlock()
        let current = [left, right].compactMap { $0 }
        for gone in previous where !current.contains(where: { $0 === gone }) {
            gone.physicalInputProfile.valueDidChangeHandler = nil
            lock.lock()
            for hand in 0...1 {
                pulsers[Self.key(gone, hand)]?.stop()
                pulsers[Self.key(gone, hand)] = nil
            }
            lock.unlock()
        }
        for (index, sense) in [left, right].enumerated() {
            guard let sense, !previous.contains(where: { $0 === sense }) else { continue }
            for (_, button) in sense.physicalInputProfile.buttons where button.isBoundToSystemGesture {
                button.preferredSystemGestureState = .disabled
            }
            sense.handlerQueue = inputQueue
            sense.physicalInputProfile.valueDidChangeHandler = { [weak self] _, _ in
                self?.publishSense()
            }
            if let haptics = sense.haptics {
                lock.lock()
                pulsers[Self.key(sense, index)] = HapticPulser(haptics: haptics, locality: .default)
                lock.unlock()
            }
        }
    }

    // MARK: - Mapping

    private func publish(_ new: pt_vp_controller) {
        lock.lock()
        state = new
        lock.unlock()
        onStateChange?(new)
    }

    /// A DualSense, DualShock 4 or other gamepad, mapped to the game's actions.
    private func publishGamepad(_ controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }
        var new = pt_vp_controller()
        new.active = true
        new.move_x = gamepad.leftThumbstick.xAxis.value
        new.move_y = gamepad.leftThumbstick.yAxis.value
        new.turn_x = gamepad.rightThumbstick.xAxis.value
        new.turn_y = gamepad.rightThumbstick.yAxis.value
        // Face buttons: on a PlayStation profile, A is Cross, B is Circle, X is Square and Y is Triangle.
        new.interact = gamepad.buttonA.isPressed
        new.back = gamepad.buttonB.isPressed
        new.gouge = gamepad.buttonX.isPressed
        new.triangle = gamepad.buttonY.isPressed
        // OPTIONS is the menu button; Create (Share on a DualShock 4) is buttonOptions.
        new.menu = gamepad.buttonMenu.isPressed
        new.zoom = gamepad.rightThumbstickButton?.isPressed ?? false
        var settings = gamepad.buttonOptions?.isPressed ?? false
        if let dualSense = gamepad as? GCDualSenseGamepad {
            settings = settings || dualSense.touchpadButton.isPressed
        } else if let dualShock = gamepad as? GCDualShockGamepad {
            settings = settings || dualShock.touchpadButton.isPressed
        }
        new.settings = settings
        // The menus: the D-pad, L1/R1 (switching the settings page's columns), and the glyphs of
        // the controller in hand.
        new.dpad_up = gamepad.dpad.up.isPressed
        new.dpad_down = gamepad.dpad.down.isPressed
        new.dpad_left = gamepad.dpad.left.isPressed
        new.dpad_right = gamepad.dpad.right.isPressed
        new.l1 = gamepad.leftShoulder.isPressed
        new.r1 = gamepad.rightShoulder.isPressed
        new.prompt_style = Self.promptStyle(controller)
        new.hand_valid = (false, false)
        publish(new)
    }

    /// The button glyphs the game shows: 1 PlayStation, 2 Nintendo, 0 Xbox (A B X Y, the default).
    private static func promptStyle(_ controller: GCController) -> Int32 {
        if isPlayStation(controller) || isSense(controller) {
            return 1
        }
        let category = controller.productCategory.lowercased()
        if category.contains("switch") || category.contains("joy-con") || category.contains("nintendo") {
            return 2
        }
        return 0
    }

    /// The two Sense controllers as one: the left one has the move stick, Square (lower face
    /// button) and Triangle (upper), and Create; the right one the turn stick, R3, Cross (lower)
    /// and Circle (upper), and OPTIONS.
    private func publishSense() {
        lock.lock()
        let left = senseLeft
        let right = senseRight
        lock.unlock()
        guard left != nil || right != nil else {
            publish(pt_vp_controller())
            return
        }
        func pressed(_ controller: GCController?, _ names: [String]) -> Bool {
            guard let profile = controller?.physicalInputProfile else { return false }
            return names.contains { profile.buttons[$0]?.isPressed ?? false }
        }
        func stick(_ controller: GCController?, _ names: [String]) -> (Float, Float) {
            guard let profile = controller?.physicalInputProfile else { return (0, 0) }
            for name in names {
                if let pad = profile.dpads[name] {
                    return (pad.xAxis.value, pad.yAxis.value)
                }
            }
            return (0, 0)
        }
        let a = GCInputButtonA, b = GCInputButtonB, x = GCInputButtonX, y = GCInputButtonY
        var new = pt_vp_controller()
        new.active = true
        let (lx, ly) = stick(left, ["Thumbstick", GCInputLeftThumbstick])
        let (rx, ry) = stick(right, ["Thumbstick", GCInputRightThumbstick])
        new.move_x = lx
        new.move_y = ly
        new.turn_x = rx
        new.turn_y = ry
        new.gouge = pressed(left, [x, a])
        new.triangle = pressed(left, [y, b])
        new.interact = pressed(right, [a, x])
        new.back = pressed(right, [b, y])
        new.zoom = pressed(right, ["Thumbstick Button", GCInputRightThumbstickButton])
        new.menu = pressed(right, [GCInputButtonOptions, GCInputButtonMenu])
        new.settings = pressed(left, [GCInputButtonShare, GCInputButtonMenu, GCInputButtonOptions])
        new.l1 = pressed(left, [GCInputLeftShoulder, "Grip Button", "Left Shoulder"])
        new.r1 = pressed(right, [GCInputRightShoulder, "Grip Button", "Right Shoulder"])
        new.prompt_style = 1
        // TODO: GameController does not give a Sense controller's pose on visionOS 2 (ARKit's
        // accessory tracking arrived with visionOS 26). Until the app tracks them, the game places
        // the flashlight with the head.
        new.hand_valid = (false, false)
        publish(new)
    }

    // MARK: - Haptics

    /// A pulse of the game's: hand 0 left, 1 right, -1 both.
    func playHaptic(hand: Int, amplitude: Float, seconds: Float) {
        lock.lock()
        var targets: [HapticPulser] = []
        let hands = hand < 0 ? [0, 1] : [min(max(hand, 0), 1)]
        if let controller {
            for h in hands {
                if let pulser = pulsers[Self.key(controller, h)] {
                    targets.append(pulser)
                }
            }
        } else {
            for h in hands {
                if let sense = h == 0 ? senseLeft : senseRight,
                   let pulser = pulsers[Self.key(sense, h)] {
                    targets.append(pulser)
                }
            }
        }
        lock.unlock()
        for pulser in targets {
            pulser.pulse(amplitude: amplitude, seconds: seconds)
        }
    }
}

/// One of the controller's motors, as a CoreHaptics engine that plays one continuous event per
/// pulse the game asks for.
final class HapticPulser: @unchecked Sendable {
    private var engine: CHHapticEngine?
    private let haptics: GCDeviceHaptics
    private let locality: GCHapticsLocality
    private let lock = NSLock()

    init?(haptics: GCDeviceHaptics, locality: GCHapticsLocality) {
        self.haptics = haptics
        self.locality = locality
        guard makeEngine() else { return nil }
    }

    private func makeEngine() -> Bool {
        guard let engine = haptics.createEngine(withLocality: locality) else {
            return false
        }
        engine.stoppedHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.engine = nil
            self.lock.unlock()
        }
        engine.resetHandler = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            try? self.engine?.start()
            self.lock.unlock()
        }
        do {
            try engine.start()
        } catch {
            return false
        }
        self.engine = engine
        return true
    }

    func pulse(amplitude: Float, seconds: Float) {
        let intensity = min(max(amplitude, 0), 1)
        guard intensity > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        if engine == nil, !makeEngine() {
            return
        }
        guard let engine else { return }
        do {
            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                             CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)],
                relativeTime: 0,
                duration: TimeInterval(max(seconds, 0.02)))
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // A pulse lost is no matter.
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        engine?.stop(completionHandler: nil)
        engine = nil
    }
}
