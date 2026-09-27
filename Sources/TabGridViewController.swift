import UIKit

public final class TabGridCardCell: UICollectionViewCell {
    public static let identifier = "TabGridCardCell"

    public var onCloseButtonTapped: (() -> Void)?

    private let headerBar: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = UIColor { trait in
            return trait.userInterfaceStyle == .dark
                ? UIColor(white: 0.22, alpha: 1.0)
                : UIColor(white: 0.94, alpha: 1.0)
        }
        return view
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .label
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private let closeButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        let config = UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        let img = UIImage(systemName: "xmark", withConfiguration: config)
        btn.setImage(img, for: .normal)
        btn.tintColor = .secondaryLabel
        btn.backgroundColor = UIColor { trait in
            return trait.userInterfaceStyle == .dark
                ? UIColor(white: 0.35, alpha: 0.8)
                : UIColor(white: 0.85, alpha: 0.8)
        }
        btn.layer.cornerRadius = 11
        btn.layer.masksToBounds = true
        return btn
    }()

    private let previewImageView: UIImageView = {
        let iv = UIImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.backgroundColor = .systemBackground
        return iv
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 14
        contentView.layer.masksToBounds = true
        contentView.backgroundColor = .systemBackground

        layer.cornerRadius = 14
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.shadowRadius = 6
        layer.shadowOpacity = 0.12
        layer.masksToBounds = false

        contentView.addSubview(headerBar)
        headerBar.addSubview(titleLabel)
        headerBar.addSubview(closeButton)
        contentView.addSubview(previewImageView)

        NSLayoutConstraint.activate([
            headerBar.topAnchor.constraint(equalTo: contentView.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: 34),

            titleLabel.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
            titleLabel.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            closeButton.heightAnchor.constraint(equalToConstant: 22),

            previewImageView.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            previewImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            previewImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            previewImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        closeButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handleClose() {
        onCloseButtonTapped?()
    }

    public func configure(tab: TabItem, isActive: Bool) {
        titleLabel.text = tab.title.isEmpty ? "新标签页" : tab.title
        previewImageView.image = tab.snapshot

        if isActive {
            contentView.layer.borderColor = UIColor.systemBlue.cgColor
            contentView.layer.borderWidth = 3.0
        } else {
            contentView.layer.borderColor = UIColor.separator.cgColor
            contentView.layer.borderWidth = 0.5
        }
    }
}

public protocol TabGridViewControllerDelegate: AnyObject {
    func tabGridDidSelectTab(at index: Int)
    func tabGridDidCloseTab(at index: Int)
    func tabGridDidCreateNewTab()
    func tabGridDidCloseAllTabs()
}

public final class TabGridViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    public weak var delegate: TabGridViewControllerDelegate?
    public var tabs: [TabItem] = []
    public var activeTabIndex: Int = 0

    private let topNavBar: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .systemGroupedBackground
        return view
    }()

    private let clearAllButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        let img = UIImage(systemName: "trash")
        btn.setImage(img, for: .normal)
        btn.tintColor = .systemBlue
        return btn
    }()

    private let navTitleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "标签页"
        label.font = UIFont.systemFont(ofSize: 17, weight: .bold)
        label.textAlignment = .center
        return label
    }()

    private let doneButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setTitle("完成", for: .normal)
        btn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 16)
        btn.tintColor = .systemBlue
        return btn
    }()

    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 14
        layout.minimumInteritemSpacing = 12
        layout.scrollDirection = .vertical
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.translatesAutoresizingMaskIntoConstraints = false
        cv.backgroundColor = .systemGroupedBackground
        cv.showsVerticalScrollIndicator = true
        cv.alwaysBounceVertical = true
        return cv
    }()

    private let addTabButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        let cfg = UIImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        btn.setImage(UIImage(systemName: "plus", withConfiguration: cfg), for: .normal)
        btn.tintColor = .white
        btn.backgroundColor = .systemBlue
        btn.layer.cornerRadius = 28
        btn.layer.masksToBounds = false
        btn.layer.shadowColor = UIColor.systemBlue.cgColor
        btn.layer.shadowOffset = CGSize(width: 0, height: 4)
        btn.layer.shadowRadius = 8
        btn.layer.shadowOpacity = 0.35
        return btn
    }()

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        setupLayout()
        setupActions()

        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(TabGridCardCell.self, forCellWithReuseIdentifier: TabGridCardCell.identifier)
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateDynamicLayoutAndScroll()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateDynamicLayoutAndScroll()
    }

    private func setupLayout() {
        view.addSubview(topNavBar)
        topNavBar.addSubview(clearAllButton)
        topNavBar.addSubview(navTitleLabel)
        topNavBar.addSubview(doneButton)

        view.addSubview(collectionView)
        view.addSubview(addTabButton)

        NSLayoutConstraint.activate([
            topNavBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topNavBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topNavBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topNavBar.heightAnchor.constraint(equalToConstant: 44),

            clearAllButton.leadingAnchor.constraint(equalTo: topNavBar.leadingAnchor, constant: 16),
            clearAllButton.centerYAnchor.constraint(equalTo: topNavBar.centerYAnchor),
            clearAllButton.widthAnchor.constraint(equalToConstant: 32),
            clearAllButton.heightAnchor.constraint(equalToConstant: 32),

            doneButton.trailingAnchor.constraint(equalTo: topNavBar.trailingAnchor, constant: -16),
            doneButton.centerYAnchor.constraint(equalTo: topNavBar.centerYAnchor),
            doneButton.heightAnchor.constraint(equalToConstant: 32),

            navTitleLabel.centerXAnchor.constraint(equalTo: topNavBar.centerXAnchor),
            navTitleLabel.centerYAnchor.constraint(equalTo: topNavBar.centerYAnchor),

            collectionView.topAnchor.constraint(equalTo: topNavBar.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            addTabButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            addTabButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            addTabButton.widthAnchor.constraint(equalToConstant: 56),
            addTabButton.heightAnchor.constraint(equalToConstant: 56)
        ])
    }

    private func setupActions() {
        doneButton.addTarget(self, action: #selector(handleDone), for: .touchUpInside)
        clearAllButton.addTarget(self, action: #selector(handleClearAll), for: .touchUpInside)
        addTabButton.addTarget(self, action: #selector(handleAddTab), for: .touchUpInside)
    }

    @objc private func handleDone() {
        dismiss(animated: true)
    }

    @objc private func handleClearAll() {
        guard !tabs.isEmpty else { return }
        let alert = UIAlertController(title: "关闭所有标签页", message: "确定要关闭全部 \(tabs.count) 个标签页吗？", preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "关闭所有标签页", style: .destructive) { [weak self] _ in
            self?.delegate?.tabGridDidCloseAllTabs()
            self?.tabs.removeAll()
            self?.collectionView.reloadData()
            self?.dismiss(animated: true)
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = clearAllButton
            popover.sourceRect = clearAllButton.bounds
        }
        present(alert, animated: true)
    }

    @objc private func handleAddTab() {
        delegate?.tabGridDidCreateNewTab()
        dismiss(animated: true)
    }

    private func updateDynamicLayoutAndScroll() {
        guard collectionView.bounds.width > 0 else { return }

        let totalTabs = tabs.count
        let rows = Int(ceil(Double(totalTabs) / 2.0))
        let width = (collectionView.bounds.width - 16 * 2 - 12) / 2
        let height = width * 1.35
        let spacing: CGFloat = 14
        let bottomPadding: CGFloat = 88 // 底部加号按钮空间
        let totalCardsHeight = CGFloat(rows) * height + CGFloat(max(0, rows - 1)) * spacing

        let visibleHeight = collectionView.bounds.height
        let topInset: CGFloat
        if totalCardsHeight + bottomPadding < visibleHeight {
            topInset = max(16, visibleHeight - bottomPadding - totalCardsHeight)
        } else {
            topInset = 16
        }

        if let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout {
            layout.sectionInset = UIEdgeInsets(top: topInset, left: 16, bottom: bottomPadding, right: 16)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let maxOffsetY = max(0, self.collectionView.contentSize.height - self.collectionView.bounds.height)
            if maxOffsetY > 0 {
                self.collectionView.setContentOffset(CGPoint(x: 0, y: maxOffsetY), animated: false)
            }
        }
    }

    public func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return tabs.count
    }

    public func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let width = (collectionView.bounds.width - 16 * 2 - 12) / 2
        return CGSize(width: width, height: width * 1.35)
    }

    public func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: TabGridCardCell.identifier, for: indexPath) as? TabGridCardCell else {
            return UICollectionViewCell()
        }
        let tab = tabs[indexPath.row]
        let isActive = (indexPath.row == activeTabIndex)
        cell.configure(tab: tab, isActive: isActive)
        cell.onCloseButtonTapped = { [weak self] in
            self?.closeTab(at: indexPath.row)
        }
        return cell
    }

    public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        delegate?.tabGridDidSelectTab(at: indexPath.row)
        dismiss(animated: true)
    }

    private func closeTab(at index: Int) {
        guard index < tabs.count else { return }
        tabs.remove(at: index)
        delegate?.tabGridDidCloseTab(at: index)

        if tabs.isEmpty {
            delegate?.tabGridDidCreateNewTab()
            dismiss(animated: true)
            return
        }

        if activeTabIndex >= tabs.count {
            activeTabIndex = tabs.count - 1
        }

        collectionView.reloadData()
        updateDynamicLayoutAndScroll()
    }
}
