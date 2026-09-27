import UIKit
import WebKit

typealias WebsiteDataViewController = WebsiteDataManagerViewController

final class WebsiteDataManagerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating {

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let searchController = UISearchController(searchResultsController: nil)
    private var allRecords: [WKWebsiteDataRecord] = []
    private var filteredRecords: [WKWebsiteDataRecord] = []

    private var isSearching: Bool {
        return searchController.isActive && !(searchController.searchBar.text?.isEmpty ?? true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadData()
    }

    private func setupUI() {
        title = "管理网站数据"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "移除", style: .plain, target: self, action: #selector(handleRemove))

        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = searchController

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func loadData() {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().fetchDataRecords(ofTypes: types) { [weak self] list in
            DispatchQueue.main.async {
                self?.allRecords = list.sorted { $0.displayName < $1.displayName }
                self?.tableView.reloadData()
            }
        }
    }

    @objc private func handleRemove() {
        let sheet = UIAlertController(title: "移除网站数据", message: "已锁定的域名受到严格保护，不会被删除。", preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "移除所有未锁定数据", style: .destructive, handler: { [weak self] _ in
            guard let self = self else { return }
            let unlocked = self.allRecords.filter { !CookieLockStore.shared.isLocked(domain: $0.displayName) }
            WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: unlocked) {
                DispatchQueue.main.async {
                    self.loadData()
                }
            }
        }))
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(sheet, animated: true)
    }

    func updateSearchResults(for searchController: UISearchController) {
        let txt = searchController.searchBar.text?.lowercased() ?? ""
        filteredRecords = allRecords.filter { $0.displayName.lowercased().contains(txt) }
        tableView.reloadData()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return isSearching ? filteredRecords.count : allRecords.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "SiteCell")
        let rec = isSearching ? filteredRecords[indexPath.row] : allRecords[indexPath.row]
        let isLocked = CookieLockStore.shared.isLocked(domain: rec.displayName)

        cell.textLabel?.text = rec.displayName
        cell.textLabel?.textColor = isLocked ? UIColor(red: 0.12, green: 0.72, blue: 0.53, alpha: 1.0) : .label
        cell.detailTextLabel?.text = rec.dataTypes.joined(separator: ", ")
        cell.accessoryType = isLocked ? .checkmark : .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let rec = isSearching ? filteredRecords[indexPath.row] : allRecords[indexPath.row]
        CookieLockStore.shared.toggleLock(domain: rec.displayName)
        tableView.reloadRows(at: [indexPath], with: .automatic)
    }
}
