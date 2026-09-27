import UIKit

final class TabGridViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private var tabs: [TabItem]
    private var activeIndex: Int
    private var collectionView: UICollectionView!
    private let topBarView = UIView()
    private let clearAllButton = TouchButton()
    private let bottomToolbar = UIView()
    private let privateModeButton = TouchButton()
    private let newTabButton = TouchButton()
    private let doneButton = TouchButton()

    var onSelectTab: ((Int) -> Void)?
    var onCloseTab: ((Int) -> Void)?
    var onClearAllTabs: (() -> Void)?
    var onNewTab: (() -> Void)?

    override var preferredStatusBarStyle: UIStatusBarStyle {
        .lightContent
    }

    init(tabs: [TabItem], activeIndex: Int) {
        self.tabs = tabs
        self.activeIndex = activeIndex
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateLayoutInsets()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if tabs.indices.contains(activeIndex) {
            collectionView.scrollToItem(at: IndexPath(item: activeIndex, section: 0), at: .centeredVertically, animated: false)
        }
    }

    private func setupUI() {
        view.backgroundColor = .clear

        let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        blurView.frame = view.bounds
        blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(blurView)

        let darkDimming = UIView()
        darkDimming.frame = view.bounds
        darkDimming.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        darkDimming.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        view.addSubview(darkDimming)

        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 16
        layout.sectionInset = UIEdgeInsets(top: 60, left: 16, bottom: 80, right: 16)

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.showsVerticalScrollIndicator = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(TabGridCell.self, forCellWithReuseIdentifier: "TabGridCell")

        view.addSubview(collectionView)

        setupTopBar()
        setupBottomToolbar()

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomToolbar.topAnchor)
        ])
    }

    private func setupTopBar() {
        topBarView.translatesAutoresizingMaskIntoConstraints = false
        topBarView.backgroundColor = .clear

        clearAllButton.translatesAutoresizingMaskIntoConstraints = false
        clearAllButton.tintColor = .white
        clearAllButton.setImage(
            UIImage(
                systemName: "trash",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
            ),
            for: .normal
        )
        clearAllButton.hitTestInsets = UIEdgeInsets(top: -10, left: -10, bottom: -10, right: -10)
        clearAllButton.addTarget(self, action: #selector(handleClearAllTabs), for: .touchUpInside)

        topBarView.addSubview(clearAllButton)
        view.addSubview(topBarView)

        NSLayoutConstraint.activate([
            topBarView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBarView.heightAnchor.constraint(equalToConstant: 44),

            clearAllButton.trailingAnchor.constraint(equalTo: topBarView.trailingAnchor, constant: -16),
            clearAllButton.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),
            clearAllButton.widthAnchor.constraint(equalToConstant: 32),
            clearAllButton.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    private func setupBottomToolbar() {
        bottomToolbar.translatesAutoresizingMaskIntoConstraints = false
        bottomToolbar.backgroundColor = .clear

        let toolbarBlur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterialDark))
        toolbarBlur.translatesAutoresizingMaskIntoConstraints = false
        bottomToolbar.addSubview(toolbarBlur)

        let topBorder = UIView()
        topBorder.translatesAutoresizingMaskIntoConstraints = false
        topBorder.backgroundColor = UIColor(white: 1.0, alpha: 0.12)
        bottomToolbar.addSubview(topBorder)

        privateModeButton.translatesAutoresizingMaskIntoConstraints = false
        privateModeButton.setTitle("无痕浏览", for: .normal)
        privateModeButton.setTitleColor(.white, for: .normal)
        privateModeButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .regular)
        privateModeButton.hitTestInsets = UIEdgeInsets(top: -10, left: -10, bottom: -10, right: -10)
        privateModeButton.addTarget(self, action: #selector(handlePrivateMode), for: .touchUpInside)

        newTabButton.translatesAutoresizingMaskIntoConstraints = false
        newTabButton.tintColor = .white
        newTabButton.setImage(
            UIImage(
                systemName: "plus",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
            ),
            for: .normal
        )
        newTabButton.hitTestInsets = UIEdgeInsets(top: -10, left: -15, bottom: -10, right: -15)
        newTabButton.addTarget(self, action: #selector(handleNewTab), for: .touchUpInside)

        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.setTitle("完成", for: .normal)
        doneButton.setTitleColor(.white, for: .normal)
        doneButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        doneButton.hitTestInsets = UIEdgeInsets(top: -10, left: -10, bottom: -10, right: -10)
        doneButton.addTarget(self, action: #selector(handleDone), for: .touchUpInside)

        bottomToolbar.addSubview(privateModeButton)
        bottomToolbar.addSubview(newTabButton)
        bottomToolbar.addSubview(doneButton)
        view.addSubview(bottomToolbar)

        NSLayoutConstraint.activate([
            bottomToolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomToolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomToolbar.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            toolbarBlur.topAnchor.constraint(equalTo: bottomToolbar.topAnchor),
            toolbarBlur.leadingAnchor.constraint(equalTo: bottomToolbar.leadingAnchor),
            toolbarBlur.trailingAnchor.constraint(equalTo: bottomToolbar.trailingAnchor),
            toolbarBlur.bottomAnchor.constraint(equalTo: bottomToolbar.bottomAnchor),

            topBorder.topAnchor.constraint(equalTo: bottomToolbar.topAnchor),
            topBorder.leadingAnchor.constraint(equalTo: bottomToolbar.leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: bottomToolbar.trailingAnchor),
            topBorder.heightAnchor.constraint(equalToConstant: 0.5),

            privateModeButton.leadingAnchor.constraint(equalTo: bottomToolbar.leadingAnchor, constant: 18),
            privateModeButton.topAnchor.constraint(equalTo: bottomToolbar.topAnchor, constant: 14),

            newTabButton.centerXAnchor.constraint(equalTo: bottomToolbar.centerXAnchor),
            newTabButton.centerYAnchor.constraint(equalTo: privateModeButton.centerYAnchor),
            newTabButton.widthAnchor.constraint(equalToConstant: 36),
            newTabButton.heightAnchor.constraint(equalToConstant: 36),

            doneButton.trailingAnchor.constraint(equalTo: bottomToolbar.trailingAnchor, constant: -18),
            doneButton.centerYAnchor.constraint(equalTo: privateModeButton.centerYAnchor),

            bottomToolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -48)
        ])
    }

    private func updateLayoutInsets(animated: Bool = false) {
        guard let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout else { return }
        guard collectionView.bounds.width > 0, collectionView.bounds.height > 0 else { return }

        let count = tabs.count
        guard count > 0 else { return }

        let width = (collectionView.bounds.width - 44) / 2
        let cellHeight = width * 1.35 + 26
        let rowCount = (count + 1) / 2
        let lineSpacing: CGFloat = 16
        let contentHeight = CGFloat(rowCount) * cellHeight + CGFloat(max(0, rowCount - 1)) * lineSpacing

        let topSafe = view.safeAreaInsets.top
        let topBarHeight = max(topSafe, 20) + 44
        let bottomSpace: CGFloat = 16
        let availableHeight = collectionView.bounds.height - topBarHeight - bottomSpace

        let newInset: UIEdgeInsets
        if contentHeight < availableHeight {
            let bottomAlignedTop = collectionView.bounds.height - bottomSpace - contentHeight
            newInset = UIEdgeInsets(
                top: max(topBarHeight + 12, bottomAlignedTop),
                left: 16,
                bottom: bottomSpace,
                right: 16
            )
        } else {
            newInset = UIEdgeInsets(
                top: topBarHeight + 12,
                left: 16,
                bottom: bottomSpace,
                right: 16
            )
        }

        if layout.sectionInset != newInset {
            layout.sectionInset = newInset
            if animated {
                UIView.animate(withDuration: 0.25) {
                    layout.invalidateLayout()
                    self.collectionView.layoutIfNeeded()
                }
            } else {
                layout.invalidateLayout()
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        tabs.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: "TabGridCell",
            for: indexPath
        ) as! TabGridCell

        let tab = tabs[indexPath.item]
        cell.configure(tab: tab, isActive: indexPath.item == activeIndex)

        cell.onClose = { [weak self] in
            self?.closeTab(at: indexPath.item)
        }

        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        onSelectTab?(indexPath.item)
        dismiss(animated: true)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let width = (view.bounds.width - 44) / 2
        return CGSize(width: width, height: width * 1.35 + 26)
    }

    private func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else {
            return
        }

        tabs.remove(at: index)

        if activeIndex == index {
            activeIndex = max(0, index - 1)
        } else if activeIndex > index {
            activeIndex -= 1
        }

        onCloseTab?(index)

        if tabs.isEmpty {
            dismiss(animated: true)
            return
        }

        updateLayoutInsets(animated: true)
        collectionView.reloadData()
    }

    @objc private func handleClearAllTabs() {
        guard !tabs.isEmpty else { return }
        let alert = UIAlertController(title: "关闭所有标签页", message: "确定要关闭全部 \(tabs.count) 个标签页吗？", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "全部关闭", style: .destructive) { [weak self] _ in
            self?.dismiss(animated: true) {
                self?.onClearAllTabs?()
            }
        })
        present(alert, animated: true)
    }

    @objc private func handleNewTab() {
        dismiss(animated: true) { [weak self] in
            self?.onNewTab?()
        }
    }

    @objc private func handleDone() {
        dismiss(animated: true)
    }

    @objc private func handlePrivateMode() {
        let alert = UIAlertController(title: "无痕浏览", message: "无痕浏览模式下将不记录访问历史与缓存。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "我知道了", style: .default))
        present(alert, animated: true)
    }
}

final class TabGridCell: UICollectionViewCell {
    private let cardContainer = UIView()
    private let thumbnailView = UIImageView()
    private let closeButton = TouchButton()
    private let titleContainer = UIView()
    private let faviconImageView = UIImageView()
    private let titleLabel = UILabel()

    var onClose: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        contentView.backgroundColor = .clear

        cardContainer.translatesAutoresizingMaskIntoConstraints = false
        cardContainer.backgroundColor = UIColor(white: 0.18, alpha: 0.8)
        cardContainer.layer.cornerRadius = 16
        cardContainer.layer.cornerCurve = .continuous
        cardContainer.layer.masksToBounds = true

        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.contentMode = .scaleAspectFill
        thumbnailView.clipsToBounds = true
        thumbnailView.backgroundColor = UIColor(white: 0.14, alpha: 1.0)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.tintColor = UIColor(white: 0.95, alpha: 1.0)
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        closeButton.layer.cornerRadius = 12
        closeButton.layer.masksToBounds = true
        closeButton.setImage(
            UIImage(
                systemName: "xmark",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)
            ),
            for: .normal
        )
        closeButton.hitTestInsets = UIEdgeInsets(top: -10, left: -10, bottom: -10, right: -10)
        closeButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)

        titleContainer.translatesAutoresizingMaskIntoConstraints = false
        titleContainer.backgroundColor = .clear

        faviconImageView.translatesAutoresizingMaskIntoConstraints = false
        faviconImageView.contentMode = .scaleAspectFit
        faviconImageView.layer.cornerRadius = 3
        faviconImageView.clipsToBounds = true
        faviconImageView.tintColor = .systemGray2

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textAlignment = .left

        cardContainer.addSubview(thumbnailView)
        cardContainer.addSubview(closeButton)

        titleContainer.addSubview(faviconImageView)
        titleContainer.addSubview(titleLabel)

        contentView.addSubview(cardContainer)
        contentView.addSubview(titleContainer)

        NSLayoutConstraint.activate([
            cardContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            cardContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            cardContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            cardContainer.bottomAnchor.constraint(equalTo: titleContainer.topAnchor, constant: -6),

            thumbnailView.topAnchor.constraint(equalTo: cardContainer.topAnchor),
            thumbnailView.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor),
            thumbnailView.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor),
            thumbnailView.bottomAnchor.constraint(equalTo: cardContainer.bottomAnchor),

            closeButton.topAnchor.constraint(equalTo: cardContainer.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),

            titleContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            titleContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            titleContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            titleContainer.heightAnchor.constraint(equalToConstant: 20),

            faviconImageView.leadingAnchor.constraint(equalTo: titleContainer.leadingAnchor),
            faviconImageView.centerYAnchor.constraint(equalTo: titleContainer.centerYAnchor),
            faviconImageView.widthAnchor.constraint(equalToConstant: 16),
            faviconImageView.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: faviconImageView.trailingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(equalTo: titleContainer.trailingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: titleContainer.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(tab: TabItem, isActive: Bool) {
        let displayTitle = tab.title.isEmpty ? (tab.url?.host ?? "新标签页") : tab.title
        titleLabel.text = displayTitle
        thumbnailView.image = tab.snapshot

        cardContainer.layer.borderWidth = isActive ? 2.5 : 0
        cardContainer.layer.borderColor = isActive ? UIColor.systemBlue.cgColor : UIColor.clear.cgColor

        faviconImageView.image = UIImage(
            systemName: "globe",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        )
        faviconImageView.tintColor = .systemGray2

        if let host = tab.url?.host {
            if let cached = FaviconLoader.shared.cachedFavicon(for: host) {
                faviconImageView.image = cached
            } else {
                FaviconLoader.shared.loadFavicon(for: host) { [weak self] img in
                    guard let img = img else { return }
                    DispatchQueue.main.async {
                        self?.faviconImageView.image = img
                    }
                }
            }
        }
    }

    @objc private func handleClose() {
        onClose?()
    }
}
