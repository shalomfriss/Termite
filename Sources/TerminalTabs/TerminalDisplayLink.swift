import AppKit
import QuartzCore

@MainActor
final class TerminalDisplayLink: NSObject {
    nonisolated static let framesPerSecond: Float = 60

    private let onFrame: () -> Void
    private var displayLink: CADisplayLink?
    private var fallbackTimer: Timer?

    init(onFrame: @escaping () -> Void) {
        self.onFrame = onFrame
        super.init()
        start()
    }

    isolated deinit {
        stop()
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    @objc private func displayLinkTick(_ sender: CADisplayLink) {
        onFrame()
    }

    private func start() {
        if let link = NSScreen.main?.displayLink(
            target: self,
            selector: #selector(displayLinkTick(_:))
        ) {
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: Self.framesPerSecond,
                maximum: Self.framesPerSecond,
                preferred: Self.framesPerSecond
            )
            link.add(to: .main, forMode: .common)
            displayLink = link
            return
        }

        let timer = Timer(timeInterval: 1 / TimeInterval(Self.framesPerSecond), repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.onFrame() }
        }
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }
}
