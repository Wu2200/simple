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

        let headerTitleLabel = UILabel()
        headerTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerTitleLabel.font = .systemFont(ofSize: 16.5, weight: .semibold)
        headerTitleLabel.textColor = .label
        headerTitleLabel.text = titleString

        let closeButton = TouchButton()
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.tintColor = .secondaryLabel
        closeButton.setImage(
            UIImage(systemName: "xmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)),
            for: .normal
        )
        closeButton.addTarget(self, action: #selector(handleDismiss), for: .touchUpInside)

        headerContainer.addSubview(headerTitleLabel)
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

            headerTitleLabel.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            headerTitleLabel.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),

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
            items[sender.tag].isSwitchOn = newState
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
    private let nameLabel = UILabel()
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

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 15.5, weight: .medium)
        nameLabel.text = item.title
        nameLabel.isUserInteractionEnabled = false

        if isDestructive {
            nameLabel.textColor = .systemRed
        } else if !isActionable {
            nameLabel.textColor = .secondaryLabel
        } else {
            nameLabel.textColor = .label
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
        addSubview(nameLabel)
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

            nameLabel.leadingAnchor.constraint(equalTo: iconCapsule.trailingAnchor, constant: 14),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: (item.isSwitchOn != nil) ? toggleSwitch.leadingAnchor : accessoryImageView.leadingAnchor, constant: -10)
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

// MARK: - 更多菜单网格项按钮

final class GridItemButton: TouchButton {
    var item: CustomBottomSheetItem
    private(set) var switchPill: UIView?
    private(set) var knob: UIView?
    private var knobLeadingConstraint: NSLayoutConstraint?
    private var knobTrailingConstraint: NSLayoutConstraint?

    init(item: CustomBottomSheetItem, tag: Int) {
        self.item = item
        super.init(frame: .zero)
        self.tag = tag
        setupContent()
    }

    required init?(coder: NSCoder) { nil }

    private func setupContent() {
        let iconColor: UIColor = item.isDestructive ? .systemRed : UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(white: 0.86, alpha: 1.0) : UIColor(red: 0.28, green: 0.28, blue: 0.31, alpha: 1.0)
        }
        let textColor: UIColor = item.isDestructive ? .systemRed : UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(white: 0.88, alpha: 1.0) : UIColor(red: 0.26, green: 0.26, blue: 0.28, alpha: 1.0)
        }

        let iconContainer = UIView()
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.isUserInteractionEnabled = false

        let iconImageView = UIImageView()
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.contentMode = .scaleAspectFit
        if let img = item.customImage {
            iconImageView.image = img
        } else if let iconName = item.iconName {
            iconImageView.image = UIImage(systemName: iconName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular))
        } else {
            iconImageView.image = UIImage(systemName: "circle.grid.2x2", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular))
        }
        iconImageView.tintColor = iconColor
        iconImageView.isUserInteractionEnabled = false
        iconContainer.addSubview(iconImageView)

        let hasSwitch = (item.isSwitchOn != nil)

        NSLayoutConstraint.activate([
            iconImageView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor, constant: hasSwitch ? -6 : 0),
            iconImageView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 24),
            iconImageView.heightAnchor.constraint(equalToConstant: 24)
        ])

        if let isOn = item.isSwitchOn {
            let pill = UIView()
            pill.translatesAutoresizingMaskIntoConstraints = false
            pill.backgroundColor = isOn ? .systemBlue : UIColor { trait in
                trait.userInterfaceStyle == .dark ? UIColor(white: 0.35, alpha: 1.0) : UIColor(red: 0.84, green: 0.84, blue: 0.86, alpha: 1.0)
            }
            pill.layer.cornerRadius = 4.75
            pill.clipsToBounds = true
            pill.isUserInteractionEnabled = false
            self.switchPill = pill

            let knobView = UIView()
            knobView.translatesAutoresizingMaskIntoConstraints = false
            knobView.backgroundColor = .white
            knobView.layer.cornerRadius = 3.5
            knobView.layer.shadowColor = UIColor.black.cgColor
            knobView.layer.shadowOpacity = 0.12
            knobView.layer.shadowRadius = 1
            knobView.layer.shadowOffset = CGSize(width: 0, height: 1)
            knobView.clipsToBounds = false
            knobView.isUserInteractionEnabled = false
            pill.addSubview(knobView)
            self.knob = knobView

            iconContainer.addSubview(pill)

            let leadingCon = knobView.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 1)
            let trailingCon = knobView.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -1)
            self.knobLeadingConstraint = leadingCon
            self.knobTrailingConstraint = trailingCon

            if isOn {
                trailingCon.isActive = true
            } else {
                leadingCon.isActive = true
            }

            NSLayoutConstraint.activate([
                pill.widthAnchor.constraint(equalToConstant: 16),
                pill.heightAnchor.constraint(equalToConstant: 9.5),
                pill.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 3),
                pill.bottomAnchor.constraint(equalTo: iconImageView.bottomAnchor, constant: -0.5),

                knobView.widthAnchor.constraint(equalToConstant: 7),
                knobView.heightAnchor.constraint(equalToConstant: 7),
                knobView.centerYAnchor.constraint(equalTo: pill.centerYAnchor)
            ])
        }

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11.5, weight: .regular)
        label.textColor = textColor
        label.text = item.title
        label.textAlignment = .center
        label.numberOfLines = 1
        label.isUserInteractionEnabled = false

        addSubview(iconContainer)
        addSubview(label)

        NSLayoutConstraint.activate([
            iconContainer.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            iconContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconContainer.heightAnchor.constraint(equalToConstant: 32),
            iconContainer.widthAnchor.constraint(equalToConstant: 48),

            label.topAnchor.constraint(equalTo: iconContainer.bottomAnchor, constant: 5),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -2)
        ])
    }

    func updateSwitchVisual(isOn: Bool, animated: Bool = true) {
        item.isSwitchOn = isOn
        let block = {
            self.switchPill?.backgroundColor = isOn ? .systemBlue : UIColor { trait in
                trait.userInterfaceStyle == .dark ? UIColor(white: 0.35, alpha: 1.0) : UIColor(red: 0.84, green: 0.84, blue: 0.86, alpha: 1.0)
            }
            if isOn {
                self.knobLeadingConstraint?.isActive = false
                self.knobTrailingConstraint?.isActive = true
            } else {
                self.knobTrailingConstraint?.isActive = false
                self.knobLeadingConstraint?.isActive = true
            }
            self.switchPill?.layoutIfNeeded()
        }

        if animated {
            UIView.animate(withDuration: 0.18, delay: 0, options: .curveEaseInOut, animations: block)
        } else {
            block()
        }
    }
}
