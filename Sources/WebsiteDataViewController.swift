import UIKit
import WebKit

// MARK: - 网站数据管理主页面
final class WebsiteDataViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating {

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let searchController = UISearchController(searchResultsController: nil)
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    private var allRecords: [WKWebsiteDataRecord] = []
    private var filteredRecords: [WKWebsiteDataRecord] = []

    private var isSearching: Bool {
        return searchController.isActive && !(searchController.searchBar.text?.isEmpty ?? true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "管理网站数据"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "移除", style: .plain, target: self, action: #selector(handleRemoveAction))
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(handleDone))

        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "搜索网站域名"
        navigationItem.searchController = searchController
        definesPresentationContext = true

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(WebsiteDataRecordCell.self, forCellReuseIdentifier: "RecordCell")
        tableView.rowHeight = 62
        view.addSubview(tableView)

        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.hidesWhenStopped = true
        view.addSubview(activityIndicator)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        loadRecords()
    }

    @objc private func handleDone() {
        dismiss(animated: true)
    }

    private func loadRecords() {
        activityIndicator.startAnimating()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().fetchDataRecords(ofTypes: types) { [weak self] records in
            DispatchQueue.main.async {
                self?.activityIndicator.stopAnimating()
                self?.allRecords = records.sorted { (r1, r2) in
                    let l1 = CookieLockStore.shared.isLocked(host: r1.displayName)
                    let l2 = CookieLockStore.shared.isLocked(host: r2.displayName)
                    if l1 != l2 { return l1 && !l2 }
                    return r1.displayName < r2.displayName
                }
                self?.tableView.reloadData()
            }
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if text.isEmpty {
            filteredRecords = []
        } else {
            filteredRecords = allRecords.filter { $0.displayName.lowercased().contains(text) }
        }
        tableView.reloadData()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return isSearching ? filteredRecords.count : allRecords.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: "RecordCell", for: indexPath) as? WebsiteDataRecordCell else {
            return UITableViewCell()
        }
        let record = isSearching ? filteredRecords[indexPath.row] : allRecords[indexPath.row]
        let locked = CookieLockStore.shared.isLocked(host: record.displayName)
        cell.configure(record: record, isLocked: locked)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let record = isSearching ? filteredRecords[indexPath.row] : allRecords[indexPath.row]
        _ = CookieLockStore.shared.toggleLock(host: record.displayName)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        tableView.reloadRows(at: [indexPath], with: .automatic)
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let record = isSearching ? filteredRecords[indexPath.row] : allRecords[indexPath.row]
        let isLocked = CookieLockStore.shared.isLocked(host: record.displayName)

        let delete = UIContextualAction(style: .destructive, title: "移除") { [weak self] (_, _, completion) in
            guard let self = self else { return }
            if isLocked {
                let alert = UIAlertController(title: "域名已被锁定", message: "若要移除该域名的数据，请先解除锁定。", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "确定", style: .default))
                self.present(alert, animated: true)
                completion(false)
                return
            }
            WKWebsiteDataStore.default().removeData(ofTypes: record.dataTypes, for: [record]) {
                DispatchQueue.main.async {
                    self.loadRecords()
                    completion(true)
                }
            }
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    @objc private func handleRemoveAction() {
        let alert = UIAlertController(title: "移除网站数据", message: "已锁定的网站数据受到严格保护，不会被删除。", preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "移除所有未锁定数据", style: .destructive, handler: { [weak self] _ in
            self?.removeUnlockedData()
        }))
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItem
        }
        present(alert, animated: true)
    }

    private func removeUnlockedData() {
        let unlocked = allRecords.filter { !CookieLockStore.shared.isLocked(host: $0.displayName) }
        guard !unlocked.isEmpty else { return }

        activityIndicator.startAnimating()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(ofTypes: types, for: unlocked) { [weak self] in
            DispatchQueue.main.async {
                self?.loadRecords()
            }
        }
    }
}

// MARK: - 网站记录单元格
final class WebsiteDataRecordCell: UITableViewCell {

    private let faviconIV = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let lockIcon = UIImageView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        backgroundColor = .secondarySystemGroupedBackground

        faviconIV.translatesAutoresizingMaskIntoConstraints = false
        faviconIV.layer.cornerRadius = 6
        faviconIV.clipsToBounds = true
        contentView.addSubview(faviconIV)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15.5, weight: .medium)
        contentView.addSubview(titleLabel)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = .secondaryLabel
        contentView.addSubview(detailLabel)

        lockIcon.translatesAutoresizingMaskIntoConstraints = false
        lockIcon.image = UIImage(systemName: "lock.fill")
        lockIcon.tintColor = UIColor(red: 0.12, green: 0.72, blue: 0.53, alpha: 1.0)
        contentView.addSubview(lockIcon)

        NSLayoutConstraint.activate([
            faviconIV.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            faviconIV.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            faviconIV.widthAnchor.constraint(equalToConstant: 28),
            faviconIV.heightAnchor.constraint(equalToConstant: 28),

            titleLabel.leadingAnchor.constraint(equalTo: faviconIV.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 11),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: lockIcon.leadingAnchor, constant: -8),

            lockIcon.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            lockIcon.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            lockIcon.widthAnchor.constraint(equalToConstant: 16),
            lockIcon.heightAnchor.constraint(equalToConstant: 16),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            detailLabel.trailingAnchor.constraint(equalTo: lockIcon.leadingAnchor, constant: -8)
        ])
    }

    func configure(record: WKWebsiteDataRecord, isLocked: Bool) {
        titleLabel.text = record.displayName
        lockIcon.isHidden = !isLocked

        var types: [String] = []
        if record.dataTypes.contains(WKWebsiteDataTypeCookies) { types.append("Cookies") }
        if record.dataTypes.contains(WKWebsiteDataTypeDiskCache) { types.append("磁盘缓存") }
        if record.dataTypes.contains(WKWebsiteDataTypeIndexedDBDatabases) { types.append("索引数据库") }
        if record.dataTypes.contains(WKWebsiteDataTypeLocalStorage) { types.append("本地存储") }
        detailLabel.text = types.isEmpty ? "本地网站数据" : types.joined(separator: ", ")

        if isLocked {
            titleLabel.textColor = UIColor(red: 0.12, green: 0.72, blue: 0.53, alpha: 1.0)
        } else {
            titleLabel.textColor = .label
        }

        faviconIV.image = UIImage(systemName: "globe")
        FaviconLoader.shared.loadFavicon(for: record.displayName) { [weak self] img in
            if let img = img {
                self?.faviconIV.image = img
            }
        }
    }
}
