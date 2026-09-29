import UIKit

enum SearchEngine: String, CaseIterable, Codable {
    case google = "google"
    case bing = "bing"
    case yandex = "yandex"

    var name: String {
        switch self {
        case .google: return "Google"
        case .bing: return "Bing"
        case .yandex: return "Yandex"
        }
    }

    func searchURL(query: String) -> URL? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        switch self {
        case .google:
            return URL(string: "https://www.google.com/search?q=\(encoded)")
        case .bing:
            return URL(string: "https://www.bing.com/search?q=\(encoded)")
        case .yandex:
            return URL(string: "https://yandex.com/search/?text=\(encoded)")
        }
    }
}

final class SearchEngineStore {
    static let shared = SearchEngineStore()
    private let key = "browser_selected_search_engine_v1"
    private init() {}

    var currentEngine: SearchEngine {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key),
                  let engine = SearchEngine(rawValue: raw) else {
                return .google
            }
            return engine
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }
}

final class SearchHistoryStore {
    static let shared = SearchHistoryStore()
    private let key = "browser_search_history_v1"

    private init() {}

    func getHistory() -> [String] {
        return UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func addHistory(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var history = getHistory()
        history.removeAll { $0 == trimmed }
        history.insert(trimmed, at: 0)
        if history.count > 100 { history = Array(history.prefix(100)) }
        UserDefaults.standard.set(history, forKey: key)
    }

    func clearHistory() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

final class AddressTextField: UITextField {
    var onLongPressAction: (() -> Void)?

    override var canBecomeFirstResponder: Bool {
        true
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(customCopyAction) ||
           action == #selector(customPasteAction) ||
           action == #selector(customEditAction) ||
           action == #selector(customPasteAndGoAction) {
            return true
        }
        if action == #selector(copy(_:)) ||
           action == #selector(paste(_:)) ||
           action == #selector(selectAll(_:)) ||
           action == #selector(select(_:)) ||
           action == #selector(cut(_:)) {
            return true
        }
        return false
    }

    @objc func customCopyAction() {
        if let text = text, !text.isEmpty {
            UIPasteboard.general.string = text
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    @objc func customPasteAction() {
        if let paste = UIPasteboard.general.string {
            text = paste
            sendActions(for: .editingChanged)
        }
    }

    @objc func customEditAction() {
        becomeFirstResponder()
        selectAll(nil)
    }

    @objc func customPasteAndGoAction() {
        if let paste = UIPasteboard.general.string {
            text = paste
            _ = delegate?.textFieldShouldReturn?(self)
        }
    }
}

final class CalloutMenuButton: UIButton {
    override var isHighlighted: Bool {
        didSet {
            let isDark = traitCollection.userInterfaceStyle == .dark
            backgroundColor = isHighlighted ?
                (isDark ? UIColor(white: 1.0, alpha: 0.12) : UIColor(white: 0.0, alpha: 0.08)) :
                .clear
        }
    }
}

final class CalloutBubbleBackgroundView: UIView {
    enum ArrowDirection {
        case up
        case down
    }

    var arrowDirection: ArrowDirection = .down {
        didSet { setNeedsLayout() }
    }

    var arrowOffset: CGFloat = 136 {
        didSet { setNeedsLayout() }
    }

    private let shapeLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }

    private func setupLayer() {
        backgroundColor = .clear
        layer.addSublayer(shapeLayer)
        updateColors()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateColors()
    }

    private func updateColors() {
        let isDark = traitCollection.userInterfaceStyle == .dark
        shapeLayer.fillColor = isDark ?
            UIColor(red: 0.20, green: 0.20, blue: 0.22, alpha: 0.98).cgColor :
            UIColor(white: 1.0, alpha: 0.98).cgColor
        shapeLayer.strokeColor = isDark ?
            UIColor(white: 1.0, alpha: 0.12).cgColor :
            UIColor(white: 0.0, alpha: 0.06).cgColor
        shapeLayer.lineWidth = 0.5

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = isDark ? 0.35 : 0.12
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 3)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        shapeLayer.frame = bounds

        let path = UIBezierPath()
        let cornerRadius: CGFloat = 12
        let arrowWidth: CGFloat = 14
        let arrowHeight: CGFloat = 7
        let halfArrow = arrowWidth / 2

        let minOffset = cornerRadius + halfArrow + 2
        let maxOffset = bounds.width - cornerRadius - halfArrow - 2
        let clampedOffset = min(max(minOffset, arrowOffset), maxOffset)

        if arrowDirection == .down {
            let bodyHeight = bounds.height - arrowHeight

            path.move(to: CGPoint(x: cornerRadius, y: 0))
            path.addLine(to: CGPoint(x: bounds.width - cornerRadius, y: 0))
            path.addArc(
                withCenter: CGPoint(x: bounds.width - cornerRadius, y: cornerRadius),
                radius: cornerRadius,
                startAngle: -CGFloat.pi / 2,
                endAngle: 0,
                clockwise: true
            )
            path.addLine(to: CGPoint(x: bounds.width, y: bodyHeight - cornerRadius))
            path.addArc(
                withCenter: CGPoint(x: bounds.width - cornerRadius, y: bodyHeight - cornerRadius),
                radius: cornerRadius,
                startAngle: 0,
                endAngle: CGFloat.pi / 2,
                clockwise: true
            )

            path.addLine(to: CGPoint(x: clampedOffset + halfArrow, y: bodyHeight))
            path.addLine(to: CGPoint(x: clampedOffset, y: bounds.height))
            path.addLine(to: CGPoint(x: clampedOffset - halfArrow, y: bodyHeight))

            path.addLine(to: CGPoint(x: cornerRadius, y: bodyHeight))
            path.addArc(
                withCenter: CGPoint(x: cornerRadius, y: bodyHeight - cornerRadius),
                radius: cornerRadius,
                startAngle: CGFloat.pi / 2,
                endAngle: CGFloat.pi,
                clockwise: true
            )
            path.addLine(to: CGPoint(x: 0, y: cornerRadius))
            path.addArc(
                withCenter: CGPoint(x: cornerRadius, y: cornerRadius),
                radius: cornerRadius,
                startAngle: CGFloat.pi,
                endAngle: -CGFloat.pi / 2,
                clockwise: true
            )
            path.close()
        } else {
            let bodyTop = arrowHeight

            path.move(to: CGPoint(x: clampedOffset - halfArrow, y: bodyTop))
            path.addLine(to: CGPoint(x: clampedOffset, y: 0))
            path.addLine(to: CGPoint(x: clampedOffset + halfArrow, y: bodyTop))

            path.addLine(to: CGPoint(x: bounds.width - cornerRadius, y: bodyTop))
            path.addArc(
                withCenter: CGPoint(x: bounds.width - cornerRadius, y: bodyTop + cornerRadius),
                radius: cornerRadius,
                startAngle: -CGFloat.pi / 2,
                endAngle: 0,
                clockwise: true
            )
            path.addLine(to: CGPoint(x: bounds.width, y: bounds.height - cornerRadius))
            path.addArc(
                withCenter: CGPoint(x: bounds.width - cornerRadius, y: bounds.height - cornerRadius),
                radius: cornerRadius,
                startAngle: 0,
                endAngle: CGFloat.pi / 2,
                clockwise: true
            )

            path.addLine(to: CGPoint(x: cornerRadius, y: bounds.height))
            path.addArc(
                withCenter: CGPoint(x: cornerRadius, y: bounds.height - cornerRadius),
                radius: cornerRadius,
                startAngle: CGFloat.pi / 2,
                endAngle: CGFloat.pi,
                clockwise: true
            )
            path.addLine(to: CGPoint(x: 0, y: bodyTop + cornerRadius))
            path.addArc(
                withCenter: CGPoint(x: cornerRadius, y: bodyTop + cornerRadius),
                radius: cornerRadius,
                startAngle: CGFloat.pi,
                endAngle: -CGFloat.pi / 2,
                clockwise: true
            )
            path.close()
        }

        shapeLayer.path = path.cgPath
        layer.shadowPath = path.cgPath
    }
}

final class AddressCalloutMenuView: UIView {
    var onCopy: (() -> Void)?
    var onPaste: (() -> Void)?
    var onEdit: (() -> Void)?
    var onPasteAndGo: (() -> Void)?

    private let backgroundView = CalloutBubbleBackgroundView()
    private let contentView = UIView()
    private let stackView = UIStackView()

    init(arrowDirection: CalloutBubbleBackgroundView.ArrowDirection, arrowOffset: CGFloat) {
        super.init(frame: .zero)
        backgroundView.arrowDirection = arrowDirection
        backgroundView.arrowOffset = arrowOffset
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        backgroundColor = .clear
        addSubview(backgroundView)
        addSubview(contentView)

        contentView.layer.cornerRadius = 12
        contentView.clipsToBounds = true

        stackView.axis = .horizontal
        stackView.alignment = .fill
        stackView.distribution = .fill
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        let btnCopy = createItemButton(title: "拷贝", action: #selector(handleCopyTapped), width: 56)
        let btnPaste = createItemButton(title: "粘贴", action: #selector(handlePasteTapped), width: 56)
        let btnEdit = createItemButton(title: "编辑", action: #selector(handleEditTapped), width: 56)
        let btnPasteAndGo = createItemButton(title: "粘贴并前往", action: #selector(handlePasteAndGoTapped), width: 94)

        stackView.addArrangedSubview(btnCopy)
        stackView.addArrangedSubview(makeSeparator())
        stackView.addArrangedSubview(btnPaste)
        stackView.addArrangedSubview(makeSeparator())
        stackView.addArrangedSubview(btnEdit)
        stackView.addArrangedSubview(makeSeparator())
        stackView.addArrangedSubview(btnPasteAndGo)
    }

    private func createItemButton(title: String, action: Selector, width: CGFloat) -> CalloutMenuButton {
        let btn = CalloutMenuButton(type: .custom)
        btn.setTitle(title, for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 14.5, weight: .regular)
        btn.setTitleColor(UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(white: 0.96, alpha: 1.0) : UIColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0)
        }, for: .normal)
        btn.addTarget(self, action: action, for: .touchUpInside)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.widthAnchor.constraint(equalToConstant: width).isActive = true
        return btn
    }

    private func makeSeparator() -> UIView {
        let sep = UIView()
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.backgroundColor = UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(white: 1.0, alpha: 0.15) : UIColor(white: 0.0, alpha: 0.12)
        }
        sep.widthAnchor.constraint(equalToConstant: 0.5).isActive = true
        return sep
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backgroundView.frame = bounds
        let arrowHeight: CGFloat = 7
        if backgroundView.arrowDirection == .down {
            contentView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - arrowHeight)
        } else {
            contentView.frame = CGRect(x: 0, y: arrowHeight, width: bounds.width, height: bounds.height - arrowHeight)
        }
    }

    @objc private func handleCopyTapped() {
        onCopy?()
    }

    @objc private func handlePasteTapped() {
        onPaste?()
    }

    @objc private func handleEditTapped() {
        onEdit?()
    }

    @objc private func handlePasteAndGoTapped() {
        onPasteAndGo?()
    }
}

final class ExpandedURLEditorViewController: UIViewController, UITextViewDelegate {
    private let initialURL: String
    private let onConfirm: (String) -> Void
    private let textView = UITextView()

    init(initialURL: String, onConfirm: @escaping (String) -> Void) {
        self.initialURL = initialURL
        self.onConfirm = onConfirm
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "编辑网址"
        view.backgroundColor = .systemBackground

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "取消",
            style: .plain,
            target: self,
            action: #selector(handleCancel)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "前往",
            style: .done,
            target: self,
            action: #selector(handleGo)
        )

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(white: 0.22, alpha: 1.0) : UIColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1.0)
        }
        container.layer.cornerRadius = 14
        container.layer.cornerCurve = .continuous
        container.clipsToBounds = true

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.backgroundColor = .clear
        textView.font = .systemFont(ofSize: 16, weight: .regular)
        textView.textColor = .label
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.text = initialURL
        textView.keyboardType = .webSearch
        textView.returnKeyType = .go
        textView.delegate = self
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)

        container.addSubview(textView)
        view.addSubview(container)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            container.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12),

            textView.topAnchor.constraint(equalTo: container.topAnchor),
            textView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.textView.becomeFirstResponder()
            if !self.textView.text.isEmpty {
                self.textView.selectAll(nil)
            }
        }
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if text == "\n" {
            handleGo()
            return false
        }
        return true
    }

    @objc private func handleCancel() {
        dismiss(animated: true)
    }

    @objc private func handleGo() {
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        dismiss(animated: true) { [weak self] in
            if !text.isEmpty {
                self?.onConfirm(text)
            }
        }
    }
}
