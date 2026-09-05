import Foundation
import CoreGraphics

struct BookmarkFolderLayout {
    static let columnWidth: CGFloat = 344
    static let twoColumnWidth: CGFloat = columnWidth * 2 + 1
    static let rowStride: CGFloat = 30
    static let fixedChromeHeight: CGFloat = 50
    static let minimumHeight: CGFloat = 102

    let maximumHeight: CGFloat
    let rowsPerColumn: Int
    let columnCount: Int
    let contentSize: CGSize

    init(
        childCount: Int,
        maximumHeight: CGFloat,
        fixedChromeHeight: CGFloat = Self.fixedChromeHeight,
        minimumHeight: CGFloat = Self.minimumHeight,
        maximumWidth: CGFloat = .greatestFiniteMagnitude
    ) {
        let safeMaximumHeight = max(minimumHeight, maximumHeight.rounded(.down))
        let availableRows = max(
            1,
            Int(floor((safeMaximumHeight - fixedChromeHeight) / Self.rowStride))
        )
        let usesTwoColumns = childCount > availableRows
        let visibleRows = usesTwoColumns ? availableRows : max(0, childCount)
        // 一列填满可用高度后再向右增加列，每列不超过 availableRows。
        let naturalHeight = usesTwoColumns
            ? safeMaximumHeight
            : max(
                minimumHeight,
                CGFloat(visibleRows) * Self.rowStride + fixedChromeHeight
            )

        self.maximumHeight = safeMaximumHeight
        self.rowsPerColumn = availableRows
        self.columnCount = max(1, (childCount + availableRows - 1) / availableRows)
        self.contentSize = CGSize(
            width: min(maximumWidth, CGFloat(columnCount) * Self.columnWidth + CGFloat(columnCount - 1)),
            height: min(safeMaximumHeight, naturalHeight)
        )
    }

    func columns<Item>(_ items: [Item]) -> [[Item]] {
        stride(from: 0, to: items.count, by: rowsPerColumn).map {
            Array(items[$0..<min($0 + rowsPerColumn, items.count)])
        }
    }
}

struct BookmarkFolderPanelGeometry {
    static let edgeGap: CGFloat = 4
    static let screenMargin: CGFloat = 8

    static func beside(_ anchor: CGRect, contentSize: CGSize, within screen: CGRect) -> CGRect {
        let width = min(contentSize.width, max(1, screen.width - screenMargin * 2))
        let height = min(contentSize.height, max(1, screen.height - screenMargin * 2))
        // No gap: a pointer or drag can cross straight into the child menu.
        let right = anchor.maxX
        let preferredX = right + width <= screen.maxX - screenMargin ? right : anchor.minX - width
        let x = max(screen.minX + screenMargin, min(preferredX, screen.maxX - screenMargin - width))
        let y = max(screen.minY + screenMargin, min(anchor.maxY - height, screen.maxY - screenMargin - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func frame(
        below anchorFrame: CGRect,
        contentSize: CGSize,
        within visibleFrame: CGRect
    ) -> CGRect {
        let maximumWidth = max(1, visibleFrame.width - screenMargin * 2)
        let width = min(contentSize.width, maximumWidth)
        let maximumHeight = max(
            1,
            anchorFrame.minY - edgeGap - visibleFrame.minY - screenMargin
        )
        let height = min(contentSize.height, maximumHeight)
        let minimumX = visibleFrame.minX + screenMargin
        let maximumX = max(minimumX, visibleFrame.maxX - screenMargin - width)
        let x = min(max(anchorFrame.minX, minimumX), maximumX)
        let y = anchorFrame.minY - edgeGap - height
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
