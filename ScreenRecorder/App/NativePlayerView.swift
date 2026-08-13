import AppKit
@preconcurrency import AVFoundation
import SwiftUI

/// A lightweight macOS video surface that avoids AVKit's SwiftUI `VideoPlayer`
/// bridge. Keeping playback on AVPlayerLayer also lets the editor own all of its
/// transport controls instead of creating a second, implicit control hierarchy.
final class NativePlayerNSView: NSView {
    private let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        layer = playerLayer
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    func setPlayer(_ player: AVPlayer?) {
        if playerLayer.player !== player {
            playerLayer.player = player
        }
    }
}

struct NativePlayerView: NSViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeNSView(context: Context) -> NativePlayerNSView {
        let view = NativePlayerNSView()
        view.setPlayer(player)
        view.layer?.contentsGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: NativePlayerNSView, context: Context) {
        nsView.setPlayer(player)
        (nsView.layer as? AVPlayerLayer)?.videoGravity = videoGravity
    }

    static func dismantleNSView(_ nsView: NativePlayerNSView, coordinator: Void) {
        nsView.setPlayer(nil)
    }
}
