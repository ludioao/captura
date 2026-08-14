import CoreGraphics
import Foundation

struct DemoFlowPlan: Equatable, Sendable {
    var layouts: [LayoutSegment]
    var webcamKeyframes: [WebcamLayoutKeyframe]
    var cameraKeyframes: [CameraKeyframe]
}

enum DemoFlowDirector {
    static func makePlan(
        duration: Double,
        introDuration: Double,
        destination: PresenterLayout,
        appearance: CanvasAppearance,
        focusTarget: CGPoint,
        sourceCutTime: Double,
        destinationCameraFrame: CGRect? = nil,
        sideBySideConfiguration: SideBySideConfiguration? = nil
    ) -> DemoFlowPlan {
        let safeDuration = max(0, duration)
        let cut = min(max(introDuration, min(1, safeDuration)), safeDuration)
        let targetX = min(max(focusTarget.x, 0), 1)
        let targetY = min(max(focusTarget.y, 0), 1)
        var destinationCamera = WebcamLayoutKeyframe.pictureInPicture(
            at: min(duration, cut + 0.45),
            appearance: appearance
        )
        if let frame = destinationCameraFrame {
            destinationCamera.positionX = min(max(frame.midX, 0), 1)
            destinationCamera.positionY = min(max(frame.midY, 0), 1)
            destinationCamera.width = min(max(frame.width, 0.08), 0.9)
            destinationCamera.height = min(max(frame.height, 0.08), 0.9)
        }
        return DemoFlowPlan(
            layouts: [
                LayoutSegment(startTime: 0, endTime: cut, layout: .cameraOnly, transitionDuration: 0.45),
                LayoutSegment(
                    startTime: cut, endTime: duration, layout: destination,
                    transitionDuration: 0.6,
                    sideBySide: destination == .sideBySide ? (sideBySideConfiguration ?? .default) : nil
                )
            ],
            webcamKeyframes: [
                .focused(at: 0),
                .focused(at: max(0, cut - 0.35)),
                destinationCamera
            ],
            cameraKeyframes: [
                CameraKeyframe(
                    time: max(0, sourceCutTime - 0.2), centerX: 0.5, centerY: 0.5,
                    scale: 1, easing: .easeInOut
                ),
                CameraKeyframe(
                    time: sourceCutTime + 0.55, centerX: targetX, centerY: targetY,
                    scale: 1.45, easing: .spring
                )
            ]
        )
    }
}
