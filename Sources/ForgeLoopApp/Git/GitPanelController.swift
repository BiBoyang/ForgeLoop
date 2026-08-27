import AppKit
import ForgeLoopGit

/// Owns the git side panel: the Changes/History/Worktrees mode switch, the
/// file/commit/worktree table, and the read-only diff view. All git data comes
/// from ForgeLoopGit; this controller only carries it into views — no git
/// logic lives here.
@MainActor
final class GitPanelController: NSObject {
    /// Which list the panel is showing.
    enum Mode: Int {
        case changes = 0
        case history = 1
        case worktrees = 2
    }

    /// One row in the panel's table.
    enum Row {
        case header(String)
        case change(GitChange, staged: Bool)
        case commit(GitCommit)
        case worktree(Worktree)
    }

    /// The panel's root view, installed into the window's split view.
    let view: NSView

    /// Called when a worktree session should open in a new tab (worktree path).
    var onOpenSession: ((String) -> Void)?

    var workingDirectory: URL
    var repoRoot: URL?
    var service: GitService?
    var worktreeService: WorktreeService?

    var modeControl: NSSegmentedControl?
    var branchLabel: NSTextField?
    var summaryLabel: NSTextField?
    var newWorktreeButton: NSButton?
    var tableView: WorktreeTableView?
    var tableScroll: NSScrollView?
    var actionBar: NSStackView?
    var openSessionButton: NSButton?
    var removeWorktreeButton: NSButton?
    var diffView: NSTextView?
    var diffScroll: NSScrollView?
    var emptyLabel: NSTextField?

    var mode: Mode = .changes
    var rows: [Row] = []
    /// Bumped on every refresh/selection so a slow git call can't overwrite a
    /// newer result — tab switches and mode changes fire loads that race.
    var generation = 0

    static let dateFormatter = RelativeDateTimeFormatter()

    init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory
        self.view = NSView()
        super.init()
        locateRepository()
        buildViewHierarchy()
        refresh()
    }

    /// Rebinds the panel to another working directory (tab switches carry their
    /// own cwd) and reloads. Outside any repository the panel shows its empty
    /// state instead of an error.
    func setWorkingDirectory(_ url: URL) {
        guard url.standardizedFileURL != workingDirectory.standardizedFileURL else {
            refresh()
            return
        }
        workingDirectory = url
        locateRepository()
        rows = []
        clearDiff()
        refresh()
    }

    func locateRepository() {
        if let root = GitRepositoryLocator.findRoot(containing: workingDirectory) {
            repoRoot = root
            service = GitService(repository: root)
            worktreeService = WorktreeService(repository: root)
        } else {
            repoRoot = nil
            service = nil
            worktreeService = nil
        }
    }

    // MARK: - View assembly

    private func buildViewHierarchy() {
        let header = makeHeaderBar()
        let summaryContainer = makeSummaryBar()
        let tableScroll = makeTableScroll()
        let actionBar = makeActionBar()
        let diffScroll = makeDiffScroll()

        let emptyLabel = NSTextField(labelWithString: "")
        emptyLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(header)
        stack.addArrangedSubview(summaryContainer)
        stack.addArrangedSubview(tableScroll)
        stack.addArrangedSubview(actionBar)
        stack.addArrangedSubview(diffScroll)
        stack.addArrangedSubview(emptyLabel)

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
            diffScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140)
        ])
        // Table and diff share the space; both give before the header does.
        tableScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        diffScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        self.emptyLabel = emptyLabel
    }

    private func makeHeaderBar() -> NSStackView {
        let modeControl = NSSegmentedControl(
            labels: ["Changes", "History", "Worktrees"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(modeChanged(_:))
        )
        modeControl.segmentStyle = .capsule
        modeControl.selectedSegment = Mode.changes.rawValue

        let branchLabel = NSTextField(labelWithString: "")
        branchLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        branchLabel.textColor = .secondaryLabelColor
        branchLabel.lineBreakMode = .byTruncatingMiddle
        branchLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        branchLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let newWorktreeButton = NSButton(title: "+", target: self, action: #selector(newWorktreePressed(_:)))
        newWorktreeButton.bezelStyle = .rounded
        newWorktreeButton.toolTip = "New worktree…"
        newWorktreeButton.isHidden = true

        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshPressed(_:)))
        refreshButton.bezelStyle = .rounded

        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 0, right: 10)
        header.addArrangedSubview(modeControl)
        header.addArrangedSubview(branchLabel)
        header.addArrangedSubview(newWorktreeButton)
        header.addArrangedSubview(refreshButton)

        self.modeControl = modeControl
        self.branchLabel = branchLabel
        self.newWorktreeButton = newWorktreeButton
        return header
    }

    private func makeSummaryBar() -> NSStackView {
        let summaryLabel = NSTextField(labelWithString: "")
        summaryLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        summaryLabel.textColor = .secondaryLabelColor
        let container = NSStackView()
        container.edgeInsets = NSEdgeInsets(top: 2, left: 10, bottom: 2, right: 10)
        container.addArrangedSubview(summaryLabel)
        self.summaryLabel = summaryLabel
        return container
    }

    private func makeTableScroll() -> NSScrollView {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        let tableView = WorktreeTableView()
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.dataSource = self
        tableView.delegate = self
        tableView.menuProvider = { [weak self] row in self?.contextMenu(forRowAt: row) }

        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = tableView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        self.tableView = tableView
        self.tableScroll = scroll
        return scroll
    }

    private func makeActionBar() -> NSStackView {
        let openButton = NSButton(title: "Open Session", target: self, action: #selector(openSessionPressed(_:)))
        openButton.bezelStyle = .rounded
        openButton.isEnabled = false
        let removeButton = NSButton(title: "Remove…", target: self, action: #selector(removeWorktreePressed(_:)))
        removeButton.bezelStyle = .rounded
        removeButton.isEnabled = false

        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        bar.addArrangedSubview(openButton)
        bar.addArrangedSubview(removeButton)
        bar.isHidden = true

        self.openSessionButton = openButton
        self.removeWorktreeButton = removeButton
        self.actionBar = bar
        return bar
    }

    private func makeDiffScroll() -> NSScrollView {
        let diffView = NSTextView()
        diffView.isEditable = false
        diffView.isSelectable = true
        diffView.usesAdaptiveColorMappingForDarkAppearance = true
        diffView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        diffView.textContainerInset = NSSize(width: 8, height: 8)

        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = diffView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        self.diffView = diffView
        self.diffScroll = scroll
        return scroll
    }

    // MARK: - Actions

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        mode = Mode(rawValue: sender.selectedSegment) ?? .changes
        rows = []
        tableView?.reloadData()
        clearDiff()
        updateWorktreeControls()
        refresh()
    }

    @objc private func refreshPressed(_ sender: NSButton) {
        refresh()
    }

    // MARK: - Loading

    /// Re-reads the repository. git's own output is the only source of truth;
    /// nothing is cached beyond the rows currently on screen.
    func refresh() {
        generation += 1
        let ticket = generation
        guard let service else {
            rows = []
            tableView?.reloadData()
            branchLabel?.stringValue = ""
            summaryLabel?.stringValue = ""
            clearDiff()
            showEmptyState(true, message: "Not a git repository")
            return
        }
        showEmptyState(false)
        let currentMode = mode
        Task { [weak self] in
            guard let self else { return }
            do {
                let branch = try await service.currentBranch()
                switch currentMode {
                case .changes:
                    let status = try await service.status()
                    guard ticket == self.generation else { return }
                    self.branchLabel?.stringValue = branch.map { "⎇ \($0)" } ?? "(detached HEAD)"
                    self.applyChanges(status)
                case .history:
                    let commits = try await service.log(limit: 200)
                    guard ticket == self.generation else { return }
                    self.branchLabel?.stringValue = branch.map { "⎇ \($0)" } ?? "(detached HEAD)"
                    self.applyHistory(commits)
                case .worktrees:
                    guard let worktreeService = self.worktreeService else { return }
                    let worktrees = try await worktreeService.list()
                    guard ticket == self.generation else { return }
                    self.branchLabel?.stringValue = branch.map { "⎇ \($0)" } ?? "(detached HEAD)"
                    self.applyWorktrees(worktrees)
                }
            } catch {
                guard ticket == self.generation else { return }
                self.summaryLabel?.stringValue = "git error: \(error.localizedDescription)"
            }
        }
    }

    private func applyChanges(_ status: GitStatus) {
        var newRows: [Row] = []
        if !status.staged.isEmpty {
            newRows.append(.header("Staged (\(status.staged.count))"))
            newRows.append(contentsOf: status.staged.map { Row.change($0, staged: true) })
        }
        if !status.unstaged.isEmpty {
            newRows.append(.header("Unstaged (\(status.unstaged.count))"))
            newRows.append(contentsOf: status.unstaged.map { Row.change($0, staged: false) })
        }
        if !status.untracked.isEmpty {
            newRows.append(.header("Untracked (\(status.untracked.count))"))
            newRows.append(contentsOf: status.untracked.map { Row.change($0, staged: false) })
        }
        rows = newRows
        let total = status.staged.count + status.unstaged.count + status.untracked.count
        summaryLabel?.stringValue = total == 0 ? "Working tree clean" : "\(total) file(s) changed"
        tableView?.reloadData()
    }

    private func applyHistory(_ commits: [GitCommit]) {
        rows = commits.map { Row.commit($0) }
        summaryLabel?.stringValue = commits.isEmpty ? "No commits yet" : "\(commits.count) commits"
        tableView?.reloadData()
    }

    private func applyWorktrees(_ worktrees: [Worktree]) {
        rows = worktrees.map { Row.worktree($0) }
        summaryLabel?.stringValue = "\(worktrees.count) worktree(s)"
        tableView?.reloadData()
        updateWorktreeControls()
    }

    private func showEmptyState(_ show: Bool, message: String? = nil) {
        emptyLabel?.stringValue = message ?? ""
        emptyLabel?.isHidden = !show
        tableScroll?.isHidden = show
        diffScroll?.isHidden = show
        modeControl?.isEnabled = !show
    }

    // MARK: - Selection

    var selectedWorktree: Worktree? {
        guard let row = tableView?.selectedRow, row >= 0, row < rows.count,
              case .worktree(let worktree) = rows[row] else { return nil }
        return worktree
    }

    func updateWorktreeControls() {
        let isWorktrees = mode == .worktrees
        newWorktreeButton?.isHidden = !isWorktrees
        actionBar?.isHidden = !isWorktrees
        openSessionButton?.isEnabled = selectedWorktree != nil
        removeWorktreeButton?.isEnabled = selectedWorktree.map { !$0.isPrimary } ?? false
    }

    func selectionChanged() {
        guard let tableView else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count else { return }
        // A new selection supersedes any in-flight diff load.
        generation += 1
        let ticket = generation
        switch rows[row] {
        case .header:
            tableView.deselectRow(row)
        case .change(let change, let staged):
            guard let service else { return }
            if change.isUntracked {
                showNotice("“\(change.name)” is untracked — no diff to show.")
                return
            }
            Task { [weak self] in
                guard let self else { return }
                do {
                    let text = try await service.diff(path: change.path, staged: staged)
                    guard ticket == self.generation else { return }
                    self.showDiff(text)
                } catch {
                    guard ticket == self.generation else { return }
                    self.showNotice("git error: \(error.localizedDescription)")
                }
            }
        case .commit(let commit):
            guard let service else { return }
            Task { [weak self] in
                guard let self else { return }
                do {
                    let text = try await service.commitDiff(commit.sha)
                    guard ticket == self.generation else { return }
                    self.showDiff(text)
                } catch {
                    guard ticket == self.generation else { return }
                    self.showNotice("git error: \(error.localizedDescription)")
                }
            }
        case .worktree(let worktree):
            let branch = worktree.branch ?? "detached HEAD"
            showNotice("\(worktree.path)\nbranch: \(branch)")
        }
        updateWorktreeControls()
    }

    // MARK: - Diff display

    func showDiff(_ text: String) {
        let files = DiffParser.parse(text)
        guard !files.isEmpty else {
            showNotice("No diff.")
            return
        }
        diffView?.textStorage?.setAttributedString(DiffRenderer.attributedString(for: files))
        diffView?.scrollToBeginningOfDocument(nil)
    }

    func showNotice(_ message: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        diffView?.textStorage?.setAttributedString(NSAttributedString(string: message, attributes: attributes))
    }

    func clearDiff() {
        diffView?.textStorage?.setAttributedString(NSAttributedString())
    }
}
