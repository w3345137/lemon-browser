import Foundation
import CoreGraphics

@main
enum TestBookmarkFolderLayout {
    static func main() {
        let short = BookmarkFolderLayout(childCount: 4, maximumHeight: 780)
        precondition(short.columnCount == 1)
        precondition(short.contentSize.width == 344)
        precondition(short.contentSize.height == 170)

        let compactScreen = BookmarkFolderLayout(childCount: 18, maximumHeight: 372)
        precondition(compactScreen.rowsPerColumn == 10)
        precondition(compactScreen.columnCount == 2)
        precondition(compactScreen.contentSize.width == 689)
        precondition(compactScreen.contentSize.height == 372)
        let compactSplit = compactScreen.columns(Array(0..<18))
        precondition(compactSplit[0] == Array(0..<10))
        precondition(compactSplit[1] == Array(10..<18))

        let veryLarge = BookmarkFolderLayout(childCount: 50, maximumHeight: 372)
        let largeSplit = veryLarge.columns(Array(0..<50))
        precondition(veryLarge.columnCount == 5)
        precondition(largeSplit.allSatisfy { $0.count == 10 })
        precondition(largeSplit.flatMap { $0 } == Array(0..<50))
        precondition(veryLarge.contentSize.width == 1724)
        let uneven = veryLarge.columns(Array(0..<53))
        precondition(uneven.count == 6 && uneven.last?.count == 3)

        let empty = BookmarkFolderLayout(childCount: 0, maximumHeight: 780)
        precondition(empty.columnCount == 1)
        precondition(empty.contentSize.height == BookmarkFolderLayout.minimumHeight)

        let overflow = BookmarkFolderLayout(
            childCount: 6,
            maximumHeight: 780,
            fixedChromeHeight: 8,
            minimumHeight: 46
        )
        precondition(overflow.columnCount == 1)
        precondition(overflow.contentSize.height == 188)

        let anchor = CGRect(x: 420, y: 690, width: 80, height: 30)
        let visibleFrame = CGRect(x: 0, y: 40, width: 1280, height: 760)
        let panelFrame = BookmarkFolderPanelGeometry.frame(
            below: anchor,
            contentSize: CGSize(width: 689, height: 620),
            within: visibleFrame
        )
        precondition(panelFrame.maxY == anchor.minY - BookmarkFolderPanelGeometry.edgeGap)
        precondition(panelFrame.minY >= visibleFrame.minY + BookmarkFolderPanelGeometry.screenMargin)
        precondition(panelFrame.maxX <= visibleFrame.maxX - BookmarkFolderPanelGeometry.screenMargin)

        let child = BookmarkFolderPanelGeometry.beside(
            anchor, contentSize: CGSize(width: 344, height: 600), within: visibleFrame)
        precondition(child.minX == anchor.maxX)
        precondition(child.maxY == anchor.maxY)
        let rightEdge = CGRect(x: 1100, y: 100, width: 160, height: 30)
        let fallback = BookmarkFolderPanelGeometry.beside(
            rightEdge, contentSize: CGSize(width: 344, height: 600), within: visibleFrame)
        precondition(fallback.maxX == rightEdge.minX)
        precondition(fallback.minY >= visibleFrame.minY + 8)
        let huge = BookmarkFolderPanelGeometry.beside(
            anchor, contentSize: CGSize(width: 3000, height: 2000), within: visibleFrame)
        precondition(visibleFrame.contains(huge))

        print("Bookmark folder layout tests passed")
    }
}
