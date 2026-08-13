import AppKit
import ApplicationServices
import Foundation
import QuartzCore

final class InteractionRecorder: NSObject, @unchecked Sendable {
    private struct EventTapBox: @unchecked Sendable {
        let value: CFMachPort
    }

    private let lock = NSLock()
    private let samplerQueue = DispatchQueue(label: "com.screenrecorder.interaction.sampler", qos: .userInteractive)
    private let metadataQueue = DispatchQueue(label: "com.screenrecorder.interaction.accessibility", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var eventTap: CFMachPort?
    private var eventRunLoop: CFRunLoop?
    private var startHostTime = 0.0
    private var pauseHostTime: Double?
    private var pausedDuration = 0.0
    private var isPaused = false
    private var displayFrame = CGRect.zero
    private var latestMousePosition: CGPoint?
    private var lastSampledPosition: CGPoint?
    private var lastMouseDown: (button: MouseButton, time: Double, point: CGPoint)?
    private var lastFrontmostBundleID: String?
    private var recordedEvents: [InteractionEvent] = []

    func start(displayFrame: CGRect) {
        lock.withLock {
            self.displayFrame = displayFrame
            startHostTime = CACurrentMediaTime()
            pauseHostTime = nil
            pausedDuration = 0
            isPaused = false
            recordedEvents.removeAll(keepingCapacity: true)
            latestMousePosition = nil
            lastSampledPosition = nil
        }
        startSampler()
        startEventTap()
        Log.interaction.info("Interaction collection started")
    }

    func pause() {
        lock.withLock {
            guard !isPaused else { return }
            isPaused = true
            pauseHostTime = CACurrentMediaTime()
        }
    }

    func resume() {
        lock.withLock {
            guard isPaused else { return }
            if let pauseHostTime { pausedDuration += CACurrentMediaTime() - pauseHostTime }
            self.pauseHostTime = nil
            isPaused = false
        }
    }

    func stop() -> [InteractionEvent] {
        timer?.cancel()
        timer = nil
        lock.withLock {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
            if let eventRunLoop { CFRunLoopStop(eventRunLoop) }
            eventTap = nil
            eventRunLoop = nil
        }
        let result = lock.withLock { recordedEvents.sorted { $0.timestamp < $1.timestamp } }
        Log.interaction.info("Interaction collection stopped with \(result.count) events")
        return result
    }

    private func startSampler() {
        let timer = DispatchSource.makeTimerSource(queue: samplerQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.sampleMouseAndWindow()
        }
        self.timer = timer
        timer.resume()
    }

    private func startEventTap() {
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .scrollWheel, .keyDown
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let recorder = Unmanaged<InteractionRecorder>.fromOpaque(userInfo).takeUnretainedValue()
                recorder.receive(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        )
        guard let tap else {
            Log.interaction.warning("Event tap unavailable; recording continues without global interaction metadata")
            return
        }
        eventTap = tap
        let tapBox = EventTapBox(value: tap)
        Thread.detachNewThread { [weak self, tapBox] in
            guard let self else { return }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tapBox.value, 0)
            let runLoop = CFRunLoopGetCurrent()
            self.lock.withLock { self.eventRunLoop = runLoop }
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tapBox.value, enable: true)
            CFRunLoopRun()
        }
    }

    private func receive(type: CGEventType, event: CGEvent) {
        guard !lock.withLock({ isPaused }) else { return }
        let point = event.location
        let timestamp = relativeTimestamp()
        lock.withLock { latestMousePosition = point }

        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let button = mouseButton(for: type)
            lock.withLock {
                lastMouseDown = (button, timestamp, point)
                recordedEvents.append(mouseEvent(type: .mouseDown, time: timestamp, point: point, button: button))
            }
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let button = mouseButton(for: type)
            var clickID: UUID?
            lock.withLock {
                recordedEvents.append(mouseEvent(type: .mouseUp, time: timestamp, point: point, button: button))
                if let down = lastMouseDown,
                   down.button == button,
                   timestamp - down.time <= 0.8,
                   hypot(point.x - down.point.x, point.y - down.point.y) <= 8 {
                    let click = mouseEvent(type: .click, time: timestamp, point: point, button: button)
                    clickID = click.id
                    recordedEvents.append(click)
                }
                lastMouseDown = nil
            }
            if let clickID { attachAccessibility(to: clickID, at: point) }
        case .scrollWheel:
            let normalized = lock.withLock { CoordinateNormalizer.normalize(point: point, in: displayFrame) }
            let item = InteractionEvent(
                type: .scroll,
                timestamp: timestamp,
                x: point.x,
                y: point.y,
                normalizedX: normalized.x,
                normalizedY: normalized.y,
                scrollDeltaX: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2),
                scrollDeltaY: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            )
            lock.withLock { recordedEvents.append(item) }
        case .keyDown:
            let item = InteractionEvent(type: .keyActivity, timestamp: timestamp, keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)), isTextInput: true)
            lock.withLock { recordedEvents.append(item) }
        default:
            break
        }
    }

    private func sampleMouseAndWindow() {
        guard !lock.withLock({ isPaused }) else { return }
        let timestamp = relativeTimestamp()
        lock.withLock {
            if let point = latestMousePosition, point != lastSampledPosition {
                recordedEvents.append(mouseEvent(type: .mouseMove, time: timestamp, point: point, button: nil))
                lastSampledPosition = point
            }
        }

        let application = NSWorkspace.shared.frontmostApplication
        let bundleID = application?.bundleIdentifier
        guard bundleID != lastFrontmostBundleID else { return }
        lastFrontmostBundleID = bundleID
        let title = frontmostWindowTitle(processID: application?.processIdentifier)
        let item = InteractionEvent(
            type: .windowFocus,
            timestamp: timestamp,
            windowTitle: title,
            applicationName: application?.localizedName
        )
        lock.withLock { recordedEvents.append(item) }
    }

    private func mouseEvent(type: InteractionEventType, time: Double, point: CGPoint, button: MouseButton?) -> InteractionEvent {
        let normalized = CoordinateNormalizer.normalize(point: point, in: displayFrame)
        return InteractionEvent(
            type: type,
            timestamp: time,
            x: point.x,
            y: point.y,
            normalizedX: normalized.x,
            normalizedY: normalized.y,
            button: button
        )
    }

    private func mouseButton(for type: CGEventType) -> MouseButton {
        switch type {
        case .leftMouseDown, .leftMouseUp: .left
        case .rightMouseDown, .rightMouseUp: .right
        default: .other
        }
    }

    private func relativeTimestamp() -> Double {
        lock.withLock {
            let currentPause = pauseHostTime.map { CACurrentMediaTime() - $0 } ?? 0
            return RelativeTimebase.timestamp(
                absoluteTime: CACurrentMediaTime(),
                origin: startHostTime,
                pausedDuration: pausedDuration + currentPause
            )
        }
    }

    private func attachAccessibility(to eventID: UUID, at point: CGPoint) {
        guard AXIsProcessTrusted() else { return }
        metadataQueue.async { [weak self] in
            guard let self, let snapshot = self.accessibilitySnapshot(at: point) else { return }
            self.lock.withLock {
                guard let index = self.recordedEvents.firstIndex(where: { $0.id == eventID }) else { return }
                self.recordedEvents[index].accessibility = snapshot
            }
        }
    }

    private func accessibilitySnapshot(at point: CGPoint) -> AccessibilityElementSnapshot? {
        let system = AXUIElementCreateSystemWide()
        var rawElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &rawElement) == .success,
              let element = rawElement else { return nil }

        let role = attribute(kAXRoleAttribute, from: element) as? String
        let title = attribute(kAXTitleAttribute, from: element) as? String
        var frame: CGRect?
        if let positionValue = attribute(kAXPositionAttribute, from: element),
           let sizeValue = attribute(kAXSizeAttribute, from: element) {
            var position = CGPoint.zero
            var size = CGSize.zero
            if AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
               AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) {
                frame = CGRect(origin: position, size: size)
            }
        }
        var processID: pid_t = 0
        AXUIElementGetPid(element, &processID)
        let app = NSRunningApplication(processIdentifier: processID)
        return AccessibilityElementSnapshot(
            role: role,
            title: title,
            frame: frame,
            applicationName: app?.localizedName,
            bundleIdentifier: app?.bundleIdentifier
        )
    }

    private func attribute(_ name: String, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func frontmostWindowTitle(processID: pid_t?) -> String? {
        guard let processID,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return windows.first {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == processID &&
            ($0[kCGWindowLayer as String] as? Int) == 0
        }?[kCGWindowName as String] as? String
    }
}
