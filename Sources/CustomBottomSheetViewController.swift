import UIKit

final class CustomBottomSheetViewController: UIViewController, UIScrollViewDelegate, UITableViewDataSource, UITableViewDelegate {
    private let titleString: String
    private var items: [CustomBottomSheetItem]
    private let layout: CustomBottomSheetLayout

    private var pageControl: UIPageControl?
    private var pagedScrollView: UIScrollView?
    private var gridButtons: [GridItemButton] = []

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
        if layout == .grid {
            setupModernGridLayout()
        } else {
            setupListLayout()
        }
    }

    private func setupModernGridLayout() {
        let grabber = UIView()
        grabber.translatesAutoresizingMaskIntoConstraints = false
        grabber.backgroundColor = .tertiaryLabel
        grabber.layer.cornerRadius = 2.5
        grabber.clipsToBounds = true
        view.addSubview(grabber)

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.isPagingEnabled = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.delegate = self
        self.pagedScrollView = scrollView
        view.addSubview(scrollView)

        let itemsPerPage = 8
        let totalPages = max(1, Int(ceil(Double(items.count) / Double(itemsPerPage))))

        let pc = UIPageControl()
        pc.translatesAutoresizingMaskIntoConstraints = false
        pc.numberOfPages = totalPages
        pc.currentPage = 0
        pc.hidesForSinglePage = true
        pc.pageIndicatorTintColor = .tertiaryLabel
        pc.currentPageIndicatorTintColor = UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(white: 0.86, alpha: 1.0) : UIColor(red: 0.28, green: 0.28, blue: 0.31, alpha: 1.0)
        }
        pc.isUserInteractionEnabled = true
        pc.addTarget(self, action: #selector(handlePageControlChange(_:)), for: .valueChanged)
        self.pageControl = pc
        view.addSubview(pc)

        NSLayoutConstraint.activate([
            grabber.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            grabber.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            grabber.widthAnchor.constraint(equalToConstant: 36),
            grabber.heightAnchor.constraint(equalToConstant: 5),

            scrollView.topAnchor.constraint(equalTo: grabber.bottomAnchor, constant: 28),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 168),

            pc.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            pc.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pc.heightAnchor.constraint(equalToConstant: (totalPages > 1 ? 16 : 0)),
            pc.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -6)
        ])

        var previousPageAnchor: NSLayoutXAxisAnchor = scrollView.contentLayoutGuide.leadingAnchor
        for pageIndex in 0..<totalPages {
            let pageView = UIView()
            pageView.translatesAutoresizingMaskIntoConstraints = false
            scrollView.addSubview(pageView)

            NSLayoutConstraint.activate([
                pageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
                pageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
                pageView.leadingAnchor.constraint(equalTo: previousPageAnchor),
                pageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
                pageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
            ])
            previousPageAnchor = pageView.trailingAnchor

            let startIndex = pageIndex * itemsPerPage
            let endIndex = min(startIndex + itemsPerPage, items.count)
            let pageItems = Array(items[startIndex..<endIndex])

            let row1 = UIStackView()
            row1.axis = .horizontal
            row1.distribution = .fillEqually
            row1.alignment = .fill
            row1.spacing = 0

            let row2 = UIStackView()
            row2.axis = .horizontal
            row2.distribution = .fillEqually
            row2.alignment = .fill
            row2.spacing = 0

            for i in 0..<4 {
                if i < pageItems.count {
                    let globalIndex = startIndex + i
                    let btn = createGridItemButton(item: pageItems[i], tag: globalIndex)
                    gridButtons.append(btn)
                    row1.addArrangedSubview(btn)
                } else {
                    let spacer = UIView()
                    row1.addArrangedSubview(spacer)
                }
            }

            for i in 4..<8 {
                if i < pageItems.count {
                    let globalIndex = startIndex + i
                    let btn = createGridItemButton(item: pageItems[i], tag: globalIndex)
                    gridButtons.append(btn)
                    row2.addArrangedSubview(btn)
                } else {
                    let spacer = UIView()
                    row2.addArrangedSubview(spacer)
                }
            }

            let pageStack = UIStackView(arrangedSubviews: [row1, row2])
            pageStack.translatesAutoresizingMaskIntoConstraints = false
            pageStack.axis = .vertical
            pageStack.distribution = .fillEqually
            pageStack.spacing = 8

            pageView.addSubview(pageStack)
            NSLayoutConstraint.activate([
                pageStack.topAnchor.constraint(equalTo: pageView.topAnchor),
                pageStack.bottomAnchor.constraint(equalTo: pageView.bottomAnchor),
                pageStack.leadingAnchor.constraint(equalTo: pageView.leadingAnchor, constant: 12),
                pageStack.trailingAnchor.constraint(equalTo: pageView.trailingAnchor, constant: -12)
            ])
        }
        scrollView.contentLayoutGuide.trailingAnchor.constraint(equalTo: previousPageAnchor).isActive = true
    }

    private func createGridItemButton(item: CustomBottomSheetItem, tag: Int) -> GridItemButton {
        let button = GridItemButton(item: item, tag: tag)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(handleItemTap(_:)), for: .touchUpInside)

        if item.longPressHandler != nil {
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleGridItemLongPress(_:)))
            longPress.minimumPressDuration = 0.45
            button.addGestureRecognizer(longPress)
        }

        return button
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.bounds.width > 0 else { return }
        let page = Int(round(scrollView.contentOffset.x / scrollView.bounds.width))
        pageControl?.currentPage = page
    }

    @objc private func handlePageControlChange(_ sender: UIPageControl) {
        guard let sv = pagedScrollView else { return }
        let offset = CGFloat(sender.currentPage) * sv.bounds.width
        sv.setContentOffset(CGPoint(x: offset, y: 0), animated: true)
    }

    // MARK: - 悬浮式未来感按钮页面 (全悬浮式浮岛卡片，消除分割线与扁平死板列表)

    private func setupListLayout() {
        let grabber = UIView()
        grabber.translatesAutoresizingMaskIntoConstraints = false
        grabber.backgroundColor = .tertiaryLabel
        grabber.layer.cornerRadius = 2.5
        grabber.clipsToBounds = true
        view.addSubview(grabber)

        let hasTitle = !titleString.isEmpty

        let headerContainer = UIView()
        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerContainer)

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 16.5, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.text = titleString

        let closeButton = TouchButton()
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.tintColor = .secondaryLabel
        closeButton.setImage(
            UIImage(systemName: "xmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)),
            for: .normal
        )
        closeButton.addTarget(self, action: #selector(handleDismiss), for: .touchUpInside)

        headerContainer.addSubview(titleLabel)
        headerContainer.addSubview(closeButton)

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        view.addSubview(scrollView)

        let stackView = UIStackView()
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.spacing = 10
        stackView.alignment = .fill
        stackView.distribution = .fill
        scrollView.addSubview(stackView)

        for (index, item) in items.enumerated() {
            let cardBtn = FloatingActionCardButton(item: item, tag: index)
            cardBtn.translatesAutoresizingMaskIntoConstraints = false
            cardBtn.heightAnchor.constraint(equalToConstant: 56).isActive = true
            cardBtn.addTarget(self, action: #selector(handleFloatingCardTap(_:)), for: .touchUpInside)
            cardBtn.onSwitchChanged = { [weak self, weak cardBtn] isOn in
                guard let self = self else { return }
                self.items[index].isSwitchOn = isOn
                cardBtn?.item.isSwitchOn = isOn
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                self.items[index].handler?()
            }
            stackView.addArrangedSubview(cardBtn)
        }

        NSLayoutConstraint.activate([
            grabber.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            grabber.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            grabber.widthAnchor.constraint(equalToConstant: 36),
            grabber.heightAnchor.constraint(equalToConstant: 5),

            headerContainer.topAnchor.constraint(equalTo: grabber.bottomAnchor, constant: hasTitle ? 8 : 0),
            headerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            headerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            headerContainer.heightAnchor.constraint(equalToConstant: hasTitle ? 36 : 0),

            titleLabel.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28),

            scrollView.topAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: hasTitle ? 8 : 12),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),

            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            stackView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32)
        ])

        headerContainer.isHidden = !hasTitle
    }

    @objc private func handleFloatingCardTap(_ sender: FloatingActionCardButton) {
        guard sender.tag < items.count else { return }
        let item = items[sender.tag]
        guard let handler = item.handler else { return }

        if item.isSwitchOn != nil && !item.dismissOnTap {
            let newState = !(item.isSwitchOn ?? false)
            item.isSwitchOn = newState
            sender.toggleSwitch.setOn(newState, animated: true)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            handler()
            return
        }

        dismiss(animated: true) {
            handler()
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        return UITableViewCell()
    }

    @objc private func handleGridItemLongPress(_ gesture: UILongPressGestureRecognizer) {
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
        if let gridBtn = sender as? GridItemButton, gridBtn.item.isSwitchOn != nil, !gridBtn.item.dismissOnTap {
            let currentState = gridBtn.item.isSwitchOn ?? false
            let newState = !currentState
            gridBtn.updateSwitchVisual(isOn: newState, animated: true)
            if sender.tag < items.count {
                items[sender.tag].isSwitchOn = newState
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            gridBtn.item.handler?()
            return
        }

        let item = (sender as? GridItemButton)?.item ?? items[sender.tag]
        dismiss(animated: true) {
            item.handler?()
        }
    }

    @objc private func handleDismiss() {
        dismiss(animated: true)
    }
}

// MARK: - 独立悬浮胶囊卡片按钮 (iOS 16/未来拟物悬浮流体风格)

final class FloatingActionCardButton: TouchButton {
    var item: CustomBottomSheetItem
    private let iconCapsule = UIView()
    private let iconImageView = UIImageView()
    private let titleLabel = UILabel()
    private let accessoryImageView = UIImageView()
    let toggleSwitch = UISwitch()

    var onSwitchChanged: ((Bool) -> Void)?

    init(item: CustomBottomSheetItem, tag: Int) {
        self.item = item
        super.init(frame: .zero)
        self.tag = tag
        setupUI()
    }

    required init?(coder: NSCoder) {
        self.item = CustomBottomSheetItem(title: "", handler: nil)
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous

        layer.borderWidth = 0.5
        layer.borderColor = UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(white: 1.0, alpha: 0.08) : UIColor(white: 0.0, alpha: 0.05)
        }.cgColor

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.04
        layer.shadowOffset = CGSize(width: 0, height: 3)
        layer.shadowRadius = 8
        clipsToBounds = false

        let isActionable = (item.handler != nil)
        let isDestructive = item.isDestructive

        iconCapsule.translatesAutoresizingMaskIntoConstraints = false
        iconCapsule.layer.cornerRadius = 11
        iconCapsule.layer.cornerCurve = .continuous
        iconCapsule.isUserInteractionEnabled = false

        if isDestructive {
            iconCapsule.backgroundColor = UIColor.systemRed.withAlphaComponent(0.12)
        } else if !isActionable {
            iconCapsule.backgroundColor = UIColor { trait in
                trait.userInterfaceStyle == .dark ? UIColor(white: 0.25, alpha: 0.6) : UIColor(white: 0.90, alpha: 0.8)
            }
        } else if item.iconName == "arrow.down.circle" {
            iconCapsule.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
        } else if item.iconName == "gearshape" {
            iconCapsule.backgroundColor = UIColor.systemPurple.withAlphaComponent(0.12)
        } else {
            iconCapsule.backgroundColor = UIColor.systemIndigo.withAlphaComponent(0.12)
        }

        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.contentMode = .scaleAspectFit
        iconImageView.isUserInteractionEnabled = false

        if let customImg = item.customImage {
            iconImageView.image = customImg
        } else if let iconName = item.iconName {
            iconImageView.image = UIImage(
                systemName: iconName,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
            )
        }

        if isDestructive {
            iconImageView.tintColor = .systemRed
        } else if !isActionable {
            iconImageView.tintColor = .secondaryLabel
        } else if item.iconName == "arrow.down.circle" {
            iconImageView.tintColor = .systemBlue
        } else if item.iconName == "gearshape" {
            iconImageView.tintColor = .systemPurple
        } else {
            iconImageView.tintColor = .systemIndigo
        }
        iconCapsule.addSubview(iconImageView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15.5, weight: .medium)
        titleLabel.text = item.title
        titleLabel.isUserInteractionEnabled = false

        if isDestructive {
            titleLabel.textColor = .systemRed
        } else if !isActionable {
            titleLabel.textColor = .secondaryLabel
        } else {
            titleLabel.textColor = .label
        }

        accessoryImageView.translatesAutoresizingMaskIntoConstraints = false
        accessoryImageView.image = UIImage(
            systemName: "chevron.forward",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        )
        accessoryImageView.tintColor = .tertiaryLabel
        accessoryImageView.contentMode = .scaleAspectFit
        accessoryImageView.isUserInteractionEnabled = false
        accessoryImageView.isHidden = !isActionable || (item.isSwitchOn != nil)

        toggleSwitch.translatesAutoresizingMaskIntoConstraints = false
        toggleSwitch.isHidden = (item.isSwitchOn == nil)
        if let isOn = item.isSwitchOn {
            toggleSwitch.isOn = isOn
            toggleSwitch.onTintColor = .systemBlue
            toggleSwitch.addTarget(self, action: #selector(handleSwitch(_:)), for: .valueChanged)
        }

        addSubview(iconCapsule)
        addSubview(titleLabel)
        addSubview(accessoryImageView)
        addSubview(toggleSwitch)

        NSLayoutConstraint.activate([
            iconCapsule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconCapsule.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconCapsule.widthAnchor.constraint(equalToConstant: 36),
            iconCapsule.heightAnchor.constraint(equalToConstant: 36),

            iconImageView.centerXAnchor.constraint(equalTo: iconCapsule.centerXAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: iconCapsule.centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 20),
            iconImageView.heightAnchor.constraint(equalToConstant: 20),

            accessoryImageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            accessoryImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            accessoryImageView.widthAnchor.constraint(equalToConstant: 12),
            accessoryImageView.heightAnchor.constraint(equalToConstant: 14),

            toggleSwitch.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            toggleSwitch.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: iconCapsule.trailingAnchor, constant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: (item.isSwitchOn != nil) ? toggleSwitch.leadingAnchor : accessoryImageView.leadingAnchor, constant: -10)
        ])
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        layer.borderColor = UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(white: 1.0, alpha: 0.08) : UIColor(white: 0.0, alpha: 0.05)
        }.cgColor
    }

    @objc private func handleSwitch(_ sender: UISwitch) {
        onSwitchChanged?(sender.isOn)
    }
}
