import CoreGraphics
import Foundation

struct ResolvedPresenterLayout: Equatable, Sendable {
    var videoRect: CGRect
    var cameraRect: CGRect
    var videoOpacity: Double
    var cameraOpacity: Double
}

enum PresenterLayoutGeometry {
    static func resolve(
        layout: PresenterLayout,
        container: CGRect,
        baseVideoRect: CGRect,
        baseCameraRect: CGRect,
        videoAspect: Double,
        videoContentMode: VideoClipContentMode,
        sideBySide: SideBySideConfiguration?
    ) -> ResolvedPresenterLayout {
        switch layout {
        case .screenOnly:
            return ResolvedPresenterLayout(
                videoRect: baseVideoRect, cameraRect: baseCameraRect,
                videoOpacity: 1, cameraOpacity: 0
            )
        case .cameraOnly:
            return ResolvedPresenterLayout(
                videoRect: baseVideoRect, cameraRect: container,
                videoOpacity: 0, cameraOpacity: 1
            )
        case .pictureInPicture:
            return ResolvedPresenterLayout(
                videoRect: baseVideoRect, cameraRect: baseCameraRect,
                videoOpacity: 1, cameraOpacity: 1
            )
        case .presenter:
            let inset = min(container.width, container.height) * 0.04
            let allocation = CGRect(
                x: container.minX + container.width * 0.61,
                y: container.minY + inset,
                width: container.width * 0.35,
                height: container.height * 0.35
            )
            return ResolvedPresenterLayout(
                videoRect: fittedVideoRect(aspect: videoAspect, in: allocation, mode: videoContentMode),
                cameraRect: container,
                videoOpacity: 1, cameraOpacity: 1
            )
        case .sideBySide:
            return resolveSideBySide(
                container: container,
                videoAspect: videoAspect,
                videoContentMode: videoContentMode,
                configuration: sideBySide ?? .default
            )
        }
    }

    static func interpolate(
        from: ResolvedPresenterLayout,
        to: ResolvedPresenterLayout,
        progress: Double
    ) -> ResolvedPresenterLayout {
        let t = min(max(progress, 0), 1)
        let eased = t * t * (3 - 2 * t)
        return ResolvedPresenterLayout(
            videoRect: interpolate(from.videoRect, to.videoRect, eased),
            cameraRect: interpolate(from.cameraRect, to.cameraRect, eased),
            videoOpacity: from.videoOpacity + (to.videoOpacity - from.videoOpacity) * eased,
            cameraOpacity: from.cameraOpacity + (to.cameraOpacity - from.cameraOpacity) * eased
        )
    }

    private static func resolveSideBySide(
        container: CGRect,
        videoAspect: Double,
        videoContentMode: VideoClipContentMode,
        configuration: SideBySideConfiguration
    ) -> ResolvedPresenterLayout {
        let config = configuration.normalized
        let axisLength = config.orientation == .horizontal ? container.width : container.height
        let gap = axisLength * config.gap
        let available = max(2, axisLength - gap)
        let screenLength = available * config.screenFraction
        let cameraLength = available - screenLength
        let firstLength = config.screenFirst ? screenLength : cameraLength

        let first: CGRect
        let second: CGRect
        if config.orientation == .horizontal {
            first = CGRect(x: container.minX, y: container.minY, width: firstLength, height: container.height)
            second = CGRect(x: first.maxX + gap, y: container.minY, width: available - firstLength, height: container.height)
        } else {
            first = CGRect(x: container.minX, y: container.minY, width: container.width, height: firstLength)
            second = CGRect(x: container.minX, y: first.maxY + gap, width: container.width, height: available - firstLength)
        }
        let screenAllocation = config.screenFirst ? first : second
        let cameraAllocation = config.screenFirst ? second : first
        return ResolvedPresenterLayout(
            videoRect: fittedVideoRect(aspect: videoAspect, in: screenAllocation, mode: videoContentMode),
            cameraRect: cameraAllocation,
            videoOpacity: 1,
            cameraOpacity: 1
        )
    }

    private static func fittedVideoRect(
        aspect: Double,
        in allocation: CGRect,
        mode: VideoClipContentMode
    ) -> CGRect {
        guard mode == .fit, aspect > 0, allocation.width > 0, allocation.height > 0 else { return allocation }
        let allocationAspect = allocation.width / allocation.height
        if aspect > allocationAspect {
            let height = allocation.width / aspect
            return CGRect(x: allocation.minX, y: allocation.midY - height / 2, width: allocation.width, height: height)
        }
        let width = allocation.height * aspect
        return CGRect(x: allocation.midX - width / 2, y: allocation.minY, width: width, height: allocation.height)
    }

    private static func interpolate(_ lhs: CGRect, _ rhs: CGRect, _ progress: Double) -> CGRect {
        CGRect(
            x: lhs.minX + (rhs.minX - lhs.minX) * progress,
            y: lhs.minY + (rhs.minY - lhs.minY) * progress,
            width: lhs.width + (rhs.width - lhs.width) * progress,
            height: lhs.height + (rhs.height - lhs.height) * progress
        )
    }
}
