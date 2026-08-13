import AppKit
import AVFoundation
import CoreGraphics
import Foundation

enum PermissionStatus: String, Sendable {
    case granted, denied, notDetermined
}

struct PermissionSnapshot: Sendable {
    var screenRecording: PermissionStatus
    var microphone: PermissionStatus
    var accessibility: PermissionStatus
}

enum PermissionCenter {
    static func current() -> PermissionSnapshot {
        PermissionSnapshot(
            screenRecording: CGPreflightScreenCaptureAccess() ? .granted : .notDetermined,
            microphone: status(for: AVCaptureDevice.authorizationStatus(for: .audio)),
            accessibility: AXIsProcessTrusted() ? .granted : .notDetermined
        )
    }

    static func requestScreenRecording() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        Log.permissions.info("Screen recording permission result: \(granted)")
        return granted
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func requestAccessibility(prompt: Bool) -> Bool {
        // String literal avoids importing the legacy mutable CF global into Swift 6 isolation.
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    private static func status(for status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }
}
