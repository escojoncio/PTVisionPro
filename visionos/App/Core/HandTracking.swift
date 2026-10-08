// SPDX-License-Identifier: MIT
//
// Hand tracking for the game's menus: ARKit's HandTrackingProvider while the immersive space is
// open, each hand's knuckle and finger tips to the core (pt_vp_set_hand), which draws a ray from
// the hand and clicks where a pinch points. Asks for the permission the first time; without it
// the core falls back to the system's look and pinch.

import ARKit
import Foundation

final class HandTracking: @unchecked Sendable {
    static let shared = HandTracking()

    private var session: ARKitSession?
    private var task: Task<Void, Never>?

    private init() {}

    /// From the immersive space's start (main thread).
    func start() {
        guard session == nil else { return }
        guard HandTrackingProvider.isSupported else {
            LogFiles.log("Hand tracking: not supported here; menus use look and pinch")
            return
        }
        let session = ARKitSession()
        let provider = HandTrackingProvider()
        self.session = session
        task = Task.detached(priority: .userInitiated) {
            let authorization = await session.requestAuthorization(for: [.handTracking])
            guard authorization[.handTracking] == .allowed else {
                LogFiles.log("Hand tracking: not allowed; menus use look and pinch")
                return
            }
            do {
                try await session.run([provider])
            } catch {
                LogFiles.log("Hand tracking: could not start (\(error.localizedDescription))")
                return
            }
            LogFiles.log("Hand tracking: on")
            for await update in provider.anchorUpdates {
                if Task.isCancelled { break }
                Self.send(update.anchor)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        session?.stop()
        session = nil
        for hand in Int32(0)...Int32(1) {
            var empty = pt_vp_hand()
            pt_vp_set_hand(hand, &empty)
        }
    }

    private static func send(_ anchor: HandAnchor) {
        let hand: Int32 = anchor.chirality == .left ? 0 : 1
        var state = pt_vp_hand()
        guard anchor.isTracked, let skeleton = anchor.handSkeleton else {
            pt_vp_set_hand(hand, &state)
            return
        }
        func position(_ joint: HandSkeleton.JointName) -> (Float, Float, Float) {
            let m = anchor.originFromAnchorTransform * skeleton.joint(joint).anchorFromJointTransform
            return (m.columns.3.x, m.columns.3.y, m.columns.3.z)
        }
        state.tracked = true
        state.index_knuckle = position(.indexFingerKnuckle)
        state.index_tip = position(.indexFingerTip)
        state.thumb_tip = position(.thumbTip)
        state.wrist = position(.wrist)
        pt_vp_set_hand(hand, &state)
    }
}
