import UIKit

final class CustomBottomSheetViewController: UIViewController {
    private let titleString: String
    private let items: [CustomBottomSheetItem]
    private let layout: CustomBottomSheetLayout

    init(title: String, items: [CustomBottomSheetItem], layout: CustomBottomSheetLayout = .list) {
        self.titleString = title
        self.items = items
        self.layout = layout
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        setupViews()
    }

    private func setupViews() {
        let headerContainer = UIView()
        headerContainer.translatesAutoresizingMaskIntoConstraints = false

        let grabber = UIView()
        grabber.translatesAutoresizingMaskIntoConstraints = false
        grabber.backgroundColor = .tertiaryLabel
        grabber.layer.cornerRadius = 2.5
        grabber.clipsToBounds = true

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.text = titleString

        let closeButton = TouchButton()
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.tintColor = .secondaryLabel
        closeButton.setImage(
            UIImage(systemName: "xmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)),
            for: .normal
        )
        closeButton.addTarget(self, action: #selector(handleDismiss), for: .touchUpInside)

        headerContainer.addSubview(grabber)
        headerContainer.addSubview(titleLabel)
        headerContainer.addSubview(closeButton)

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = false

        if layout == .grid {
            setupGridLayout(in: scrollView)
        } else {
            setupListLayout(in: scrollView)
        }

        view.addSubview(headerContainer)
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            headerContainer.topAnchor.constraint(equalTo: view.topAnchor),
            headerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerContainer.heightAnchor.constraint(equalToConstant: 54),

            grabber.topAnchor.constraint(equalTo: headerContainer.topAnchor, constant: 8),
            grabber.centerXAnchor.constraint(equalTo: headerContainer.centerXAnchor),
            grabber.widthAnchor.constraint(equalToConstant: 36),
            grabber.heightAnchor.constraint(equalToConstant: 5),

            titleLabel.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 20),
            titleLabel.bottomAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: -8),

            closeButton.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -16),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 30),
            closeButton.heightAnchor.constraint(equalToConstant: 30),

            scrollView.topAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])
    }

    private func setupGridLayout(in scrollView: UIScrollView) {
        let mainStack = UIStackView()
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.axis = .vertical
        mainStack.spacing = 10

        var rowStack: UIStackView?
        for (idx, item) in items.enumerated() {
            if idx % 2 == 0 {
                rowStack = UIStackView()
                rowStack?.axis = .horizontal
                rowStack?.spacing = 10
                rowStack?.distribution = .fillEqually
                mainStack.addArrangedSubview(rowStack!)
            }

            let card = createGridCardButton(item: item, tag: idx)
            rowStack?.addArrangedSubview(card)
        }

        if items.count % 2 != 0 {
            let spacer = UIView()
            rowStack?.addArrangedSubview(spacer)
        }

        scrollView.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            mainStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])
    }

    private func setupListLayout(in scrollView: UIScrollView) {
        let itemsStack = UIStackView()
        itemsStack.translatesAutoresizingMaskIntoConstraints = false
        itemsStack.axis = .vertical
        itemsStack.spacing = 8

        for (idx, item) in items.enumerated() {
            let card = createListCardButton(item: item, tag: idx)
            itemsStack.addArrangedSubview(card)
        }

        scrollView.addSubview(itemsStack)
        NSLayoutConstraint.activate([
            itemsStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            itemsStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            itemsStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            itemsStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            itemsStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])
    }

    private func createGridCardButton(item: CustomBottomSheetItem, tag: Int) -> TouchButton {
        let card = TouchButton()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 14
        card.layer.borderWidth = 0.5
        card.layer.borderColor = UIColor.separator.withAlphaComponent(0.25).cgColor
        card.clipsToBounds = true
        card.tag = tag
        card.addTarget(self, action: #selector(handleItemTap(_:)), for: .touchUpInside)

        if item.longPressHandler != nil {
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleItemLongPress(_:)))
            longPress.minimumPressDuration = 0.45
            card.addGestureRecognizer(longPress)
        }

        let iconImageView = UIImageView()
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.contentMode = .scaleAspectFit
        let iconName = item.iconName ?? "circle.grid.2x2"
        let iconColor: UIColor = item.isDestructive ? .systemRed : .systemBlue
        iconImageView.image = UIImage(systemName: iconName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium))
        iconImageView.tintColor = iconColor

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = item.isDestructive ? .systemRed : .label
        label.text = item.title
        label.textAlignment = .center
        label.numberOfLines = 2
        label.lineBreakMode = .byTruncatingTail

        card.addSubview(iconImageView)
        card.addSubview(label)

        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 72),

            iconImageView.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            iconImageView.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 24),
            iconImageView.heightAnchor.constraint(equalToConstant: 24),

            label.topAnchor.constraint(equalTo: iconImageView.bottomAnchor, constant: 6),
            label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            label.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -8)
        ])

        return card
    }

    private func createListCardButton(item: CustomBottomSheetItem, tag: Int) -> TouchButton {
        let card = TouchButton()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 13
        card.layer.borderWidth = 0.5
        card.layer.borderColor = UIColor.separator.withAlphaComponent(0.25).cgColor
        card.clipsToBounds = true
        card.tag = tag
        card.addTarget(self, action: #selector(handleItemTap(_:)), for: .touchUpInside)

        if item.longPressHandler != nil {
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleItemLongPress(_:)))
            longPress.minimumPressDuration = 0.45
            card.addGestureRecognizer(longPress)
        }

        let iconImageView = UIImageView()
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.contentMode = .scaleAspectFit
        let iconName = item.iconName ?? "doc.plaintext"
        let iconColor: UIColor = item.isDestructive ? .systemRed : .systemBlue
        iconImageView.image = UIImage(systemName: iconName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        iconImageView.tintColor = iconColor

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = item.isDestructive ? .systemRed : .label
        label.text = item.title
        label.numberOfLines = 1

        let chevron = UIImageView(image: UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)))
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.tintColor = .tertiaryLabel
        chevron.isHidden = (item.handler == nil)

        card.addSubview(iconImageView)
        card.addSubview(label)
        card.addSubview(chevron)

        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 50),

            iconImageView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            iconImageView.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 22),
            iconImageView.heightAnchor.constraint(equalToConstant: 22),

            label.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: card.centerYAnchor),

            chevron.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            chevron.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 14)
        ])

        return card
    }

    @objc private func handleItemLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }

        let tag = gesture.view?.tag ?? 0
        guard tag < items.count else { return }
        let item = items[tag]
        guard let handler = item.longPressHandler else { return }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        dismiss(animated: true) {
            handler()
        }
    }

    @objc private func handleItemTap(_ sender: UIButton) {
        let item = items[sender.tag]
        dismiss(animated: true) {
            item.handler?()
        }
    }

    @objc private func handleDismiss() {
        dismiss(animated: true)
    }
}
