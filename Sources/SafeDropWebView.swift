import UIKit
import WebKit
import UniformTypeIdentifiers

final class SafeDropWebView: WKWebView, UIDropInteractionDelegate {
    private struct DropPayload {
        let name: String
        let mimeType: String
        let base64: String
    }

    var onDropNotice: ((String) -> Void)?
    private let maxDropFileBytes = 50 * 1024 * 1024
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
        let location = session.location(in: self)
        dispatchDragEvent(name: "dragenter", at: location)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        let location = session.location(in: self)
        dispatchDragEvent(name: "dragover", at: location)
        return UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
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

        let group = DispatchGroup()
        var payloads: [DropPayload] = []
        var hasOversized = false
        var hasFailure = false

        for item in items {
            let provider = item.itemProvider
            guard let typeId = preferredTypeIdentifier(for: provider) else {
                payloadQueue.sync { hasFailure = true }
                continue
            }

            let metadata = resolvedFileMetadata(for: provider, typeIdentifier: typeId)
            group.enter()
            provider.loadDataRepresentation(forTypeIdentifier: typeId) { [weak self] data, _ in
                guard let self = self else {
                    group.leave()
                    return
                }

                if let data = data, !data.isEmpty {
                    if data.count > self.maxDropFileBytes {
                        self.payloadQueue.sync { hasOversized = true }
                    } else {
                        let encoded = data.base64EncodedString()
                        self.payloadQueue.sync {
                            payloads.append(DropPayload(name: metadata.name, mimeType: metadata.mimeType, base64: encoded))
                        }
                    }
                    group.leave()
                    return
                }

                if provider.canLoadObject(ofClass: UIImage.self) {
                    _ = provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
                        guard let self = self else {
                            group.leave()
                            return
                        }
                        if let image = object as? UIImage, let pngData = image.pngData(), !pngData.isEmpty {
                            if pngData.count > self.maxDropFileBytes {
                                self.payloadQueue.sync { hasOversized = true }
                            } else {
                                let baseName = (metadata.name as NSString).deletingPathExtension
                                let imageName = baseName.isEmpty ? "image.png" : "\(baseName).png"
                                let encoded = pngData.base64EncodedString()
                                self.payloadQueue.sync {
                                    payloads.append(DropPayload(name: imageName, mimeType: "image/png", base64: encoded))
                                }
                            }
                        } else {
                            self.payloadQueue.sync { hasFailure = true }
                        }
                        group.leave()
                    }
                } else {
                    self.payloadQueue.sync { hasFailure = true }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            let collected = self.payloadQueue.sync { payloads }
            let oversized = self.payloadQueue.sync { hasOversized }
            let failed = self.payloadQueue.sync { hasFailure }

            if !collected.isEmpty {
                self.injectDroppedFiles(collected, at: dropPoint)
                if oversized {
                    self.onDropNotice?("部分文件超过 50MB 已跳过，请用网页上传按钮")
                }
            } else if oversized {
                self.onDropNotice?("拖入文件超过 50MB，请点击网页上传按钮选择")
            } else if failed {
                self.onDropNotice?("无法读取拖入文件，请点击网页上传按钮选择")
            }
        }
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

    private func preferredTypeIdentifier(for provider: NSItemProvider) -> String? {
        let skippedTypes: Set<String> = [
            UTType.fileURL.identifier,
            "com.apple.uikit.dragitem",
            "com.apple.finder.node",
            "com.apple.spotlight.item",
            "com.apple.Pasteboard.promised-file-url"
        ]
        let genericTypes: Set<String> = [
            UTType.data.identifier,
            UTType.item.identifier,
            UTType.content.identifier
        ]
        let candidates = provider.registeredTypeIdentifiers.filter { !skippedTypes.contains($0) }
        if let concrete = candidates.first(where: { !genericTypes.contains($0) }) {
            return concrete
        }
        if let generic = candidates.first {
            return generic
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
            return UTType.data.identifier
        }
        return provider.registeredTypeIdentifiers.first
    }

    private func resolvedFileMetadata(for provider: NSItemProvider, typeIdentifier: String) -> (name: String, mimeType: String) {
        let utType = UTType(typeIdentifier)
        let mimeType = utType?.preferredMIMEType ?? "application/octet-stream"
        let preferredExt = utType?.preferredFilenameExtension

        let rawName = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !rawName.isEmpty {
            let hasExt = !(rawName as NSString).pathExtension.isEmpty
            if hasExt {
                return (rawName, mimeType)
            }
            if let ext = preferredExt, !ext.isEmpty {
                return ("\(rawName).\(ext)", mimeType)
            }
            return (rawName, mimeType)
        }

        if let ext = preferredExt, !ext.isEmpty {
            return ("dropped_file.\(ext)", mimeType)
        }
        return ("dropped_file.bin", mimeType)
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

    private func injectDroppedFiles(_ payloads: [DropPayload], at point: CGPoint) {
        let filesPayload = payloads.map { [
            "name": $0.name,
            "type": $0.mimeType,
            "base64": $0.base64
        ] }
        let js = """
        const dt = new DataTransfer();
        for (const item of files) {
            const bin = atob(item.base64);
            const len = bin.length;
            const bytes = new Uint8Array(len);
            for (let i = 0; i < len; i++) {
                bytes[i] = bin.charCodeAt(i);
            }
            const file = new File([bytes], item.name, { type: item.type || 'application/octet-stream' });
            dt.items.add(file);
        }
        const target = document.elementFromPoint(x, y) || document.body || document.documentElement;
        if (!target) return;
        let fileInput = null;
        if (target.tagName === 'INPUT' && target.type === 'file') {
            fileInput = target;
        } else if (target.closest) {
            const directInput = target.closest('input[type="file"]');
            if (directInput) {
                fileInput = directInput;
            } else {
                const label = target.closest('label');
                if (label && label.control && label.control.tagName === 'INPUT' && label.control.type === 'file') {
                    fileInput = label.control;
                }
            }
        }
        const eventInit = {
            bubbles: true,
            cancelable: true,
            composed: true,
            clientX: x,
            clientY: y,
            dataTransfer: dt
        };
        target.dispatchEvent(new DragEvent('dragenter', eventInit));
        target.dispatchEvent(new DragEvent('dragover', eventInit));
        const dropEvent = new DragEvent('drop', eventInit);
        if (!dropEvent.dataTransfer || !dropEvent.dataTransfer.files || dropEvent.dataTransfer.files.length === 0) {
            try {
                Object.defineProperty(dropEvent, 'dataTransfer', { value: dt });
            } catch (e) {}
        }
        target.dispatchEvent(dropEvent);
        if (fileInput && !dropEvent.defaultPrevented) {
            try {
                fileInput.files = dt.files;
                fileInput.dispatchEvent(new Event('input', { bubbles: true }));
                fileInput.dispatchEvent(new Event('change', { bubbles: true }));
            } catch (e) {}
        }
        """
        callAsyncJavaScript(
            js,
            arguments: [
                "files": filesPayload,
                "x": point.x,
                "y": point.y
            ],
            in: nil,
            in: .page,
            completionHandler: nil
        )
    }
}
