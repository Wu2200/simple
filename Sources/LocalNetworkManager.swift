import Foundation
import Network

final class LocalNetworkManager {
    static let shared = LocalNetworkManager()

    private var browser: NWBrowser?
    private var hasTriggered = false

    private init() {}

    func triggerLocalNetworkPrompt() {
        guard !hasTriggered else { return }
        hasTriggered = true

        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        let browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: parameters)
        self.browser = browser

        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready, .failed:
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self?.stopBrowser()
                }
            default:
                break
            }
        }

        browser.start(queue: .main)

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.stopBrowser()
        }
    }

    private func stopBrowser() {
        browser?.cancel()
        browser = nil
    }
}
