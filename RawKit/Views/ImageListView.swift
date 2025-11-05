import AppKit
import SwiftUI

struct ImageListView: View {
    let images: [ImageInfo]
    @Binding var selectedIndices: Set<Int>
    @Binding var displayedIndex: Int?
    let onDelete: (Set<Int>) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("图像库")
                    .font(.headline)
                    .padding()
                Spacer()
            }

            KeyHandlingListView(
                images: images,
                selectedIndices: $selectedIndices,
                displayedIndex: $displayedIndex,
                onDelete: onDelete
            )
        }
        .frame(minWidth: 250)
    }
}

struct KeyHandlingListView: NSViewRepresentable {
    let images: [ImageInfo]
    @Binding var selectedIndices: Set<Int>
    @Binding var displayedIndex: Int?
    let onDelete: (Set<Int>) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let tableView = KeyHandlingTableView()
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.onDeleteKey = { [weak tableView] in
            guard let tableView else { return }
            let indices = tableView.selectedRowIndexes
            if !indices.isEmpty {
                onDelete(Set(indices))
            }
        }
        tableView.onClearSelection = { [weak tableView] in
            guard let tableView else { return }
            tableView.deselectAll(nil)
            context.coordinator.selectedIndices.wrappedValue.removeAll()
        }
        tableView.onDoubleClick = { row in
            context.coordinator.displayedIndex.wrappedValue = row
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ImageColumn"))
        column.width = 250
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.allowsMultipleSelection = true
        tableView.intercellSpacing = NSSize(width: 0, height: 0)

        scrollView.documentView = tableView

        context.coordinator.tableView = tableView
        context.coordinator.updateData(images: images, selectedIndices: selectedIndices)

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tableView = nsView.documentView as? NSTableView else { return }
        context.coordinator.updateData(images: images, selectedIndices: selectedIndices)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            images: images,
            selectedIndices: $selectedIndices,
            displayedIndex: $displayedIndex
        )
    }

    class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var images: [ImageInfo]
        var selectedIndices: Binding<Set<Int>>
        var displayedIndex: Binding<Int?>
        weak var tableView: NSTableView?
        var lastSelectedIndex: Int?
        var isUpdatingSelection = false

        init(
            images: [ImageInfo],
            selectedIndices: Binding<Set<Int>>,
            displayedIndex: Binding<Int?>
        ) {
            self.images = images
            self.selectedIndices = selectedIndices
            self.displayedIndex = displayedIndex
        }

        func updateData(images: [ImageInfo], selectedIndices: Set<Int>) {
            self.images = images
            tableView?.reloadData()

            isUpdatingSelection = true
            let indexSet = IndexSet(selectedIndices)
            tableView?.selectRowIndexes(indexSet, byExtendingSelection: false)
            isUpdatingSelection = false
        }

        func numberOfRows(in _: NSTableView) -> Int {
            images.count
        }

        func tableView(_: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
            let cellView = NSTableCellView()

            let stackView = NSStackView()
            stackView.orientation = .horizontal
            stackView.spacing = 12
            stackView.translatesAutoresizingMaskIntoConstraints = false

            let imageView = NSImageView()
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.image = images[row].thumbnail
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = 6
            imageView.layer?.masksToBounds = true
            imageView.translatesAutoresizingMaskIntoConstraints = false

            let isDisplayed = displayedIndex.wrappedValue == row
            if isDisplayed {
                imageView.layer?.borderWidth = 2
                imageView.layer?.borderColor = NSColor.controlAccentColor.cgColor
            }

            NSLayoutConstraint.activate([
                imageView.widthAnchor.constraint(equalToConstant: 60),
                imageView.heightAnchor.constraint(equalToConstant: 60),
            ])

            let textStack = NSStackView()
            textStack.orientation = .vertical
            textStack.alignment = .leading
            textStack.spacing = 4

            let nameLabel = NSTextField(labelWithString: images[row].filename)
            nameLabel.font = .systemFont(ofSize: 13)
            nameLabel.lineBreakMode = .byTruncatingTail

            let typeLabel = NSTextField(labelWithString: images[row].fileType.displayName)
            typeLabel.font = .systemFont(ofSize: 11)
            typeLabel.textColor = .secondaryLabelColor

            textStack.addArrangedSubview(nameLabel)
            textStack.addArrangedSubview(typeLabel)

            stackView.addArrangedSubview(imageView)
            stackView.addArrangedSubview(textStack)

            cellView.addSubview(stackView)
            NSLayoutConstraint.activate([
                stackView.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 8),
                stackView.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -8),
                stackView.topAnchor.constraint(equalTo: cellView.topAnchor, constant: 4),
                stackView.bottomAnchor.constraint(equalTo: cellView.bottomAnchor, constant: -4),
            ])

            return cellView
        }

        func tableView(_: NSTableView, heightOfRow _: Int) -> CGFloat {
            72
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdatingSelection else { return }
            guard let tableView = notification.object as? NSTableView else { return }
            selectedIndices.wrappedValue = Set(tableView.selectedRowIndexes)
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            guard let event = NSApp.currentEvent else {
                return true
            }

            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                let clickCount = event.clickCount

                if clickCount == 1 {
                    let commandPressed = event.modifierFlags.contains(.command)
                    let shiftPressed = event.modifierFlags.contains(.shift)

                    if commandPressed {
                        lastSelectedIndex = row
                        return true
                    } else if shiftPressed, let last = lastSelectedIndex {
                        let range = min(last, row) ... max(last, row)
                        let newSelection = IndexSet(range)

                        DispatchQueue.main.async { [weak self] in
                            self?.isUpdatingSelection = true
                            tableView.selectRowIndexes(newSelection, byExtendingSelection: false)
                            self?.isUpdatingSelection = false
                            self?.selectedIndices.wrappedValue = Set(newSelection)
                        }
                        return false
                    } else {
                        lastSelectedIndex = row
                        return true
                    }
                }
            }

            return true
        }
    }
}

class KeyHandlingTableView: NSTableView {
    var onDeleteKey: (() -> Void)?
    var onClearSelection: (() -> Void)?
    var onDoubleClick: ((Int) -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 {
            onDeleteKey?()
        } else if event.keyCode == 53 {
            onClearSelection?()
        } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "a" {
            selectAll(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)

        if event.clickCount == 2, row >= 0 {
            onDoubleClick?(row)
            return
        }

        if row == -1, event.clickCount == 1 {
            onClearSelection?()
        } else {
            super.mouseDown(with: event)
        }
    }

    override var acceptsFirstResponder: Bool {
        true
    }
}

struct ImageRowView: View {
    let imageInfo: ImageInfo

    var body: some View {
        HStack(spacing: 12) {
            if let thumbnail = imageInfo.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 60, height: 60)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(imageInfo.filename)
                    .font(.body)
                    .lineLimit(1)

                Text(imageInfo.fileType.displayName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
