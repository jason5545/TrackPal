import CoreGraphics
import Foundation

// 放開時的中鍵與角落動作。
extension ZoneScrollEngine {

    func handleMiddleClickTap(endPosition: CGPoint, endTime: Double) {
        guard !contact.forceActionTriggered else { return }

        let duration = endTime - contact.touchStartTime
        let movement = hypot(
            endPosition.x - contact.touchStartPosition.x,
            endPosition.y - contact.touchStartPosition.y
        )

        guard movement < tapMaxMovement else {
            effects.log(String(format: "Middle click ignored: moved too far (movement=%.4f max=%.4f)",
                                         movement, tapMaxMovement))
            return
        }

        guard duration < forcePressMaxDuration else {
            effects.log(String(format: "Middle click ignored: held too long without force (duration=%.3fs max=%.3fs maxForce=%.1f)",
                                         duration, forcePressMaxDuration, contact.forcePressMaxForce))
            return
        }

        guard contact.forcePressSatisfied else {
            effects.log(String(format: "Middle click ignored: no press signal (maxForce=%.1f)", contact.forcePressMaxForce))
            return
        }

        effects.log(String(format: "Middle click press accepted: source=%@ maxForce=%.1f", contact.forcePressSource, contact.forcePressMaxForce))
        postMiddleClickEvent()
    }

    func handleCornerTap(zone: ScrollZone, endPosition: CGPoint, endTime: Double) {
        guard !contact.forceActionTriggered else { return }

        let duration = endTime - contact.touchStartTime
        let movement = hypot(
            endPosition.x - contact.touchStartPosition.x,
            endPosition.y - contact.touchStartPosition.y
        )

        // Check if it's a valid force tap (short-ish duration, minimal movement)
        guard duration < forcePressMaxDuration && movement < tapMaxMovement else {
            effects.log(String(format: "Corner action ignored: release guard failed (zone=%@ duration=%.3fs movement=%.4f maxDuration=%.3fs maxMovement=%.4f maxForce=%.1f)",
                                         String(describing: zone), duration, movement,
                                         forcePressMaxDuration, tapMaxMovement, contact.forcePressMaxForce))
            return
        }

        // Get the action for this corner
        let action = configuration.cornerActions[zone]

        guard action != .none else {
            return
        }

        guard contact.forcePressSatisfied else {
            effects.log(String(format: "Corner action ignored: no force press (zone=%@ maxForce=%.1f)",
                                         String(describing: zone), contact.forcePressMaxForce))
            return
        }

        effects.log(String(format: "Corner action accepted: zone=%@ source=%@ maxForce=%.1f",
                                     String(describing: zone), contact.forcePressSource, contact.forcePressMaxForce))
        executeCornerAction(action)
    }

    func postMiddleClickEvent() {
        if effects.postMiddleClick() {
            effects.log("Middle click triggered")
        }
    }

    func executeCornerAction(_ action: CornerAction) {
        switch action {
        case .none:
            break

        case .rightClick:
            effects.performCornerAction(action)
            engageHorizontalScrollLockAfterRightClick()
            effects.log("Right click triggered")

        case .missionControl:
            effects.performCornerAction(action)
            effects.log("Mission Control triggered")

        case .appWindows:
            effects.performCornerAction(action)
            effects.log("App Windows triggered")

        case .showDesktop:
            effects.performCornerAction(action)
            effects.log("Show Desktop triggered")

        case .launchpad:
            effects.performCornerAction(action)
            effects.log("Launchpad triggered")

        case .notificationCenter:
            effects.performCornerAction(action)
            effects.log("Notification Center triggered")
        }
    }
}
