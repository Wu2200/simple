import UIKit
import WebKit

public final class TabGridViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    public weak var delegate: TabGridDelegate?

    public var tabs: [TabItem] = []
    public var selectedIndex: Int = 0

    private var collectionView: UICollectionView!
    private let topBar = UIView()
    private let trashButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let doneButton = UIButton(type: .system)
    private let addTabButton = UIButton(type: .system)

    public init(tabs: [TabItem], selectedIndex: Int) {
        self.tabs = tabs
        self.selectedIndex = selectedIndex
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateLayoutInsets()
    }

    private func setupUI() {
        view.backgroundColor = .systemGroupedBackground

        // 顶部工具栏
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        trashButton.translatesAutoresizingMaskIntoConstraints = false
        trashButton.setImage(UIImage(systemName: "trash"), for: .normal)
        trashButton.tintColor = .systemBlue
        trashButton.addTarget(self, action: #selector(handleTrashTapped), for: .touchUpInside)
        topBar.addSubview(trashButton)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "标签页"
        titleLabel.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textAlignment = .center
        topBar.addSubview(titleLabel)

        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.setTitle("完成", for: .normal)
        doneButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 17)
        doneButton.tintColor = .systemBlue
        doneButton.addTarget(self, action: #selector(handleDoneTapped), for: .touchUpInside)
        topBar.addSubview(doneButton)

        // 网格视图
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 16
        layout.minimumInteritemSpacing = 16
        layout.scrollDirection = .vertical

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.showsVerticalScrollIndicator = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(TabGridCell.self, forCellWithReuseIdentifier: TabGridCell.identifier)
        view.addSubview(collectionView)

        // 底部居中圆形新建按钮（图 1 样式）
        addTabButton.translatesAutoresizingMaskIntoConstraints = false
        addTabButton.setImage(UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .bold)), for: .normal)
        addTabButton.tintColor = .white
        addTabButton.backgroundColor = .systemBlue
        addTabButton.layer.cornerRadius = 28
        addTabButton.layer.shadowColor = UIColor.black.cgColor
        addTabButton.layer.shadowOpacity = 0.2
        addTabButton.layer.shadowOffset = CGSize(width: 0, height: 4)
        addTabButton.layer.shadowRadius = 8
        addTabButton.addTarget(self, action: #selector(handleAddTabTapped), for: .touchUpInside)
        view.addSubview(addTabButton)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 48),

            trashButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            trashButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            trashButton.widthAnchor.constraint(equalToConstant: 40),
            trashButton.heightAnchor.constraint(equalToConstant: 40),

            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            doneButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -16),
            doneButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            doneButton.heightAnchor.constraint(equalToConstant: 40),

            collectionView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: addTabButton.topAnchor, constant: -12),

            addTabButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            addTabButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            addTabButton.widthAnchor.constraint(equalToConstant: 56),
            addTabButton.heightAnchor.constraint(equalToConstant: 56)
        ])
    }

    /// 自底向上动态计算 Section Inset：
    /// 标签页少于一屏时紧贴底部（靠在加号按钮上方）；
    /// 增加至第 3 个标签页时，前两个标签页位于上一行，第 3 个标签页在最下方一行；
    /// 超过一屏时自动支持顺畅滚动。
    private func updateLayoutInsets() {
        guard let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout else { return }

        let columns: CGFloat = 2
        let padding: CGFloat = 16
        let spacing: CGFloat = 16
        let totalWidth = collectionView.bounds.width
        guard totalWidth > 0 else { return }

        let itemWidth = floor((totalWidth - padding * 2 - spacing * (columns - 1)) / columns)
        let itemHeight = floor(itemWidth * 1.35)

        layout.itemSize = CGSize(width: itemWidth, height: itemHeight)

        let totalTabs = tabs.count
        let rows = max(1, Int(ceil(Double(totalTabs) / Double(columns))))
        let totalContentHeight = CGFloat(rows) * itemHeight + CGFloat(max(0, rows - 1)) * spacing
        let availableHeight = collectionView.bounds.height

        let topInset: CGFloat
        if availableHeight > totalContentHeight && totalTabs > 0 {
            // 不足一屏时贴底：将空白留给上方
            topInset = availableHeight - totalContentHeight - 8
        } else {
            topInset = 8
        }

        let newInsets = UIEdgeInsets(top: max(8, topInset), left: padding, bottom: 8, right: padding)
        if layout.sectionInset != newInsets {
            layout.sectionInset = newInsets
            layout.invalidateLayout()
        }
    }

    @objc private func handleDoneTapped() {
        dismiss(animated: true)
    }

    @objc private func handleAddTabTapped() {
        delegate?.tabGridDidRequestNewTab()
        dismiss(animated: true)
    }

    @objc private func handleTrashTapped() {
        guard !tabs.isEmpty else { return }
        let alert = UIAlertController(title: "关闭所有标签页", message: "确定要关闭全部 \(tabs.count) 个标签页吗？", preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "关闭全部标签页", style: .destructive, handler: { [weak self] _ in
            guard let self = self else { return }
            self.tabs.removeAll()
            self.collectionView.reloadData()
            self.delegate?.tabGridDidRequestCloseAllTabs()
            self.dismiss(animated: true)
        }))
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - UICollectionView DataSource & Delegate

    public func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return tabs.count
    }

    public func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: TabGridCell.identifier, for: indexPath) as! TabGridCell
        let tab = tabs[indexPath.item]
        let isSelected = (indexPath.item == selectedIndex)

        // 同步配置所有静态内容，杜绝异步刷新与位移
        cell.configure(tab: tab, isSelected: isSelected)

        cell.onClose = { [weak self] in
            self?.closeTab(at: indexPath.item)
        }

        return cell
    }

    public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        delegate?.tabGridDidSelectTab(at: indexPath.item)
        dismiss(animated: true)
    }

    private func closeTab(at index: Int) {
        guard index < tabs.count else { return }
        let removedTab = tabs.remove(at: index)
        delegate?.tabGridDidCloseTab(removedTab, at: index)

        if tabs.isEmpty {
            delegate?.tabGridDidRequestNewTab()
            dismiss(animated: true)
            return
        }

        if index <= selectedIndex {
            selectedIndex = max(0, selectedIndex - 1)
        }

        updateLayoutInsets()
        collectionView.reloadData()
    }
}

// MARK: - 标签页卡片 Cell（图 1 风格：卡片内顶部标题栏 + 缩略图）

public final class TabGridCell: UICollectionViewCell {
    public static let identifier = "TabGridCell"

    public var onClose: (() -> Void)?

    private let cardContainer = UIView()
    private let headerView = UIView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .custom)
    private let thumbnailImageView = UIImageView()

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        contentView.backgroundColor = .clear

        // 卡片外容器
        cardContainer.translatesAutoresizingMaskIntoConstraints = false
        cardContainer.backgroundColor = UIColor { trait in
            return trait.userInterfaceStyle == .dark ? UIColor(white: 0.2, alpha: 1.0) : .white
        }
        cardContainer.layer.cornerRadius = 14
        cardContainer.layer.masksToBounds = true
        contentView.addSubview(cardContainer)

        // 内部顶部标题栏（高度固定 38pt，标题从一开始就定死在顶部）
        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.backgroundColor = UIColor { trait in
            return trait.userInterfaceStyle == .dark ? UIColor(white: 0.24, alpha: 1.0) : UIColor(white: 0.96, alpha: 1.0)
        }
        cardContainer.addSubview(headerView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.lineBreakMode = .byTruncatingTail
        headerView.addSubview(titleLabel)

        // 右上角圆形关闭小叉号
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        let config = UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        let closeImg = UIImage(systemName: "xmark", withConfiguration: config)
        closeButton.setImage(closeImg, for: .normal)
        closeButton.tintColor = .secondaryLabel
        closeButton.backgroundColor = UIColor { trait in
            return trait.userInterfaceStyle == .dark ? UIColor(white: 0.35, alpha: 1.0) : UIColor(white: 0.88, alpha: 1.0)
        }
        closeButton.layer.cornerRadius = 11
        closeButton.layer.masksToBounds = true
        closeButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)
        headerView.addSubview(closeButton)

        // 网页快照缩略图
        thumbnailImageView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailImageView.contentMode = .scaleAspectFill
        thumbnailImageView.clipsToBounds = true
        thumbnailImageView.backgroundColor = UIColor { trait in
            return trait.userInterfaceStyle == .dark ? UIColor(white: 0.15, alpha: 1.0) : UIColor(white: 0.93, alpha: 1.0)
        }
        cardContainer.addSubview(thumbnailImageView)

        NSLayoutConstraint.activate([
            cardContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            cardContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            cardContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            cardContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            headerView.topAnchor.constraint(equalTo: cardContainer.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 38),

            titleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),

            closeButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            closeButton.heightAnchor.constraint(equalToConstant: 22),

            thumbnailImageView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            thumbnailImageView.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor),
            thumbnailImageView.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor),
            thumbnailImageView.bottomAnchor.constraint(equalTo: cardContainer.bottomAnchor)
        ])
    }

    @objc private func handleClose() {
        onClose?()
    }

    public func configure(tab: TabItem, isSelected: Bool) {
        // 同步直接赋值，不进行任何延时，标题绝不位移跳动
        let displayTitle = (tab.title.isEmpty || tab.title == "新标签页") ? (tab.url?.host ?? "新标签页") : tab.title
        titleLabel.text = displayTitle
        thumbnailImageView.image = tab.snapshot

        if isSelected {
            cardContainer.layer.borderColor = UIColor.systemBlue.cgColor
            cardContainer.layer.borderWidth = 3.0
        } else {
            cardContainer.layer.borderColor = UIColor.separator.cgColor
            cardContainer.layer.borderWidth = 0.5
        }
    }
}
