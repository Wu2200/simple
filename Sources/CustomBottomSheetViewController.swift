import UIKit

final class CustomBottomSheetViewController: UIViewController, UIScrollViewDelegate {
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
        view.backgroundColor = .systemBackground
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

        let collapseButton = TouchButton()
        collapseButton.translatesAutoresizingMaskIntoConstraints = false
        collapseButton.tintColor = UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(white: 0.65, alpha: 1.0) : UIColor(red: 0.48, green: 0.48, blue: 0.51, alpha: 1.0)
        }
        collapseButton.setImage(
            UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)),
            for: .normal
        )
        collapseButton.hitTestInsets = UIEdgeInsets(top: -10, left: -40, bottom: -10, right: -40)
        collapseButton.addTarget(self, action: #selector(handleDismiss), for: .touchUpInside)
        view.addSubview(collapseButton)

        NSLayoutConstraint.activate([
            grabber.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            grabber.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            grabber.widthAnchor.constraint(equalToConstant: 36),
            grabber.heightAnchor.constraint(equalToConstant: 5),

            scrollView.topAnchor.constraint(equalTo: grabber.bottomAnchor, constant: 18),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 168),

            pc.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 4),
            pc.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pc.heightAnchor.constraint(equalToConstant: (totalPages > 1 ? 16 : 0)),

            collapseButton.topAnchor.constraint(equalTo: pc.bottomAnchor, constant: 2),
            collapseButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            collapseButton.heightAnchor.constraint(equalToConstant: 32),
            collapseButton.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -2)
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
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleItemLongPress(_:)))
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

    private func setupListLayout() {
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
        titleLabel.textColor = UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(white: 0.88, alpha: 1.0) : UIColor(red: 0.26, green: 0.26, blue: 0.28, alpha: 1.0)
        }
        titleLabel.text = titleString

        let closeButton = TouchButton()
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.tintColor = UIColor(red: 0.50, green: 0.50, blue: 0.53, alpha: 1.0)
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

        let itemsStack = UIStackView()
        itemsStack.translatesAutoresizingMaskIntoConstraints = false
        itemsStack.axis = .vertical
        itemsStack.spacing = 8

        for (idx, item) in items.enumerated() {
            let card = createListCardButton(item: item, tag: idx)
            itemsStack.addArrangedSubview(card)
        }

        scrollView.addSubview(itemsStack)
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
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),

            itemsStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            itemsStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            itemsStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            itemsStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            itemsStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])
    }

    private func createListCardButton(item: CustomBottomSheetItem, tag: Int) -> TouchButton {
        let card = TouchButton()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
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
        let iconColor: UIColor = item.isDestructive ? .systemRed : UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(white: 0.86, alpha: 1.0) : UIColor(red: 0.28, green: 0.28, blue: 0.31, alpha: 1.0)
        }
        if let img = item.customImage {
            iconImageView.image = img
        } else {
            let iconName = item.iconName ?? "doc.plaintext"
            iconImageView.image = UIImage(systemName: iconName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular))
        }
        iconImageView.tintColor = iconColor

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 15, weight: .regular)
        label.textColor = item.isDestructive ? .systemRed : UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(white: 0.88, alpha: 1.0) : UIColor(red: 0.26, green: 0.26, blue: 0.28, alpha: 1.0)
        }
        label.text = item.title
        label.numberOfLines = 1

        let chevron = UIImageView(image: UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .medium)))
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.tintColor = UIColor(red: 0.65, green: 0.65, blue: 0.68, alpha: 1.0)
        chevron.isHidden = (item.handler == nil)

        card.addSubview(iconImageView)
        card.addSubview(label)
        card.addSubview(chevron)

        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 48),

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
