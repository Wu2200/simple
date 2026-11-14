import UIKit
import WebKit
import UniformTypeIdentifiers

final class SafeDropWebView: WKWebView, UIDropInteractionDelegate {
    var onDropNotice: ((String) -> Void)?
    private let payloadQueue = DispatchQueue(label: "com.simplebrowser.safedrop.payloads")

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        setupDropInteraction()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupDropInteraction()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        suppressWebKitDropInteractions()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        suppressWebKitDropInteractions()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        suppressWebKitDropInteractions()
        return super.hitTest(point, with: event)
    }

    private func setupDropInteraction() {
        let dropInteraction = UIDropInteraction(delegate: self)
        addInteraction(dropInteraction)
        suppressWebKitDropInteractions()
    }

    private func suppressWebKitDropInteractions() {
        suppressDropInteractions(in: self)
    }

    private func suppressDropInteractions(in rootView: UIView) {
        for subview in rootView.subviews {
            for interaction in subview.interactions where interaction is UIDropInteraction {
                subview.removeInteraction(interaction)
            }
            suppressDropInteractions(in: subview)
        }
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        !session.items.isEmpty
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: UIDropSession) {
        guard session.items.allSatisfy({ isPureTextItem($0.itemProvider) }) else { return }
        let location = session.location(in: self)
        dispatchDragEvent(name: "dragenter", at: location)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        if session.items.allSatisfy({ isPureTextItem($0.itemProvider) }) {
            let location = session.location(in: self)
            dispatchDragEvent(name: "dragover", at: location)
        }
        return UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
        guard session.items.allSatisfy({ isPureTextItem($0.itemProvider) }) else { return }
        let location = session.location(in: self)
        dispatchDragEvent(name: "dragleave", at: location)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        let dropPoint = session.location(in: self)
        let items = session.items
        guard !items.isEmpty else { return }

        if items.allSatisfy({ isPureTextItem($0.itemProvider) }) {
            handleTextDrop(items: items, at: dropPoint)
            return
        }

        dispatchDragEvent(name: "dragleave", at: dropPoint)
        onDropNotice?("当前签名环境不支持跨应用文件拖入，请点击网页选择文件上传")
    }

    private func isPureTextItem(_ provider: NSItemProvider) -> Bool {
        if let suggested = provider.suggestedName, !suggested.isEmpty {
            return false
        }
        let types = provider.registeredTypeIdentifiers
        if types.contains(UTType.fileURL.identifier) {
            return false
        }
        let textAndURLTypes: Set<String> = [
            UTType.plainText.identifier,
            UTType.utf8PlainText.identifier,
            "public.utf16-plain-text",
            "public.utf16-external-plain-text",
            UTType.text.identifier,
            UTType.url.identifier,
            "public.rtf",
            "com.apple.flat-rtfd"
        ]
        if types.contains(where: { !textAndURLTypes.contains($0) }) {
            return false
        }
        return provider.canLoadObject(ofClass: String.self)
    }

    private func handleTextDrop(items: [UIDragItem], at point: CGPoint) {
        let group = DispatchGroup()
        var texts: [String] = []

        for item in items {
            let provider = item.itemProvider
            guard provider.canLoadObject(ofClass: String.self) else { continue }
            group.enter()
            _ = provider.loadObject(ofClass: String.self) { [weak self] object, _ in
                if let str = object as? String, !str.isEmpty {
                    self?.payloadQueue.sync {
                        texts.append(str)
                    }
                }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            let joined = self.payloadQueue.sync { texts.joined(separator: "\n") }
            guard !joined.isEmpty else { return }
            self.injectDroppedText(joined, at: point)
        }
    }

    private func dispatchDragEvent(name: String, at point: CGPoint) {
        let js = """
        const target = document.elementFromPoint(x, y) || document.body || document.documentElement;
        if (!target) return;
        const ev = new DragEvent(eventName, {
            bubbles: true,
            cancelable: true,
            composed: true,
            clientX: x,
            clientY: y
        });
        target.dispatchEvent(ev);
        """
        callAsyncJavaScript(
            js,
            arguments: [
                "eventName": name,
                "x": point.x,
                "y": point.y
            ],
            in: nil,
            in: .page,
            completionHandler: nil
        )
    }

    private func injectDroppedText(_ text: String, at point: CGPoint) {
        let js = """
        const target = document.elementFromPoint(x, y) || document.activeElement || document.body;
        if (!target) return;
        const dt = new DataTransfer();
        dt.setData('text/plain', text);
        const eventInit = {
            bubbles: true,
            cancelable: true,
            composed: true,
            clientX: x,
            clientY: y,
            dataTransfer: dt
        };
        const dropEvent = new DragEvent('drop', eventInit);
        target.dispatchEvent(dropEvent);
        if (!dropEvent.defaultPrevented) {
            if (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA') {
                const start = target.selectionStart ?? target.value.length;
                const end = target.selectionEnd ?? target.value.length;
                const val = target.value || '';
                target.value = val.slice(0, start) + text + val.slice(end);
                target.dispatchEvent(new Event('input', { bubbles: true }));
                target.dispatchEvent(new Event('change', { bubbles: true }));
            } else if (target.isContentEditable) {
                target.focus();
                document.execCommand('insertText', false, text);
            }
        }
        """
        callAsyncJavaScript(
            js,
            arguments: [
                "text": text,
                "x": point.x,
                "y": point.y
            ],
            in: nil,
            in: .page,
            completionHandler: nil
        )
    }
}
