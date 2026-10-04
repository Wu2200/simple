import UIKit
import Network

final class LocalNetworkAuthorizer {
    static let shared = LocalNetworkAuthorizer()
    private var browser: NWBrowser?

    func triggerAuthorization() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: parameters)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.stop()
            }
        }
        browser.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            self?.stop()
        }
    }

    private func stop() {
        browser?.cancel()
        browser = nil
    }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        LocalNetworkAuthorizer.shared.triggerAuthorization()

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = BrowserViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

class TouchButton: UIButton {
    private let hapticGenerator = UIImpactFeedbackGenerator(style: .medium)
    var hitTestInsets: UIEdgeInsets = .zero

    convenience init() {
        self.init(frame: .zero)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupFeedback()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupFeedback()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if hitTestInsets == .zero {
            return super.point(inside: point, with: event)
        }
        let enlargedBounds = bounds.inset(by: hitTestInsets)
        return enlargedBounds.contains(point)
    }

    private func setupFeedback() {
        addTarget(self, action: #selector(handleTouchDown), for: .touchDown)
        addTarget(self, action: #selector(handleTouchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }

    @objc private func handleTouchDown() {
        hapticGenerator.impactOccurred()
        UIView.animate(withDuration: 0.08) {
            self.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        }
    }

    @objc private func handleTouchUp() {
        UIView.animate(withDuration: 0.12) {
            self.transform = .identity
        }
    }
}
