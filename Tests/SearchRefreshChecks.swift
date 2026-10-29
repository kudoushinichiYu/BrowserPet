import AppKit

private final class ObservedTable:NSTableView {
    var fullReloads = 0,partialReloads = 0
    override func reloadData() { fullReloads += 1;super.reloadData() }
    override func reloadData(forRowIndexes rows:IndexSet,columnIndexes columns:IndexSet) {
        partialReloads += 1;super.reloadData(forRowIndexes:rows,columnIndexes:columns)
    }
}

@main struct SearchRefreshChecks {
    static func main() {
        _ = NSApplication.shared
        UserDefaults.standard.setVolatileDomain(["grouping.mode":0],forName:UserDefaults.argumentDomain)
        let table = ObservedTable(),controller = SearchController(isDemo:true,table:table)
        let tabs = (0..<120).map { index in
            BrowserTab(windowID:"refresh-test",tabID:String(index),title:String(format:"Page %03d",index),url:"https://example.test/page/\(index)",
                windowTitle:"Synthetic window",windowNumber:1,isActive:index == 0,browserSession:"session-one")
        }
        controller.setTabs(tabs,currentWindowID:"refresh-test")
        controller.panel.contentView?.layoutSubtreeIfNeeded()
        let full = table.fullReloads,partial = table.partialReloads,index = table.selectedRow
        let original = table.view(atColumn:0,row:index,makeIfNecessary:true)
        for _ in 0..<8 { controller.setTabs(tabs.shuffled(),currentWindowID:"refresh-test") }
        precondition(table.fullReloads == full && table.partialReloads == partial,"Unchanged polling rebuilt table views")
        precondition(table.selectedRow == index && table.view(atColumn:0,row:index,makeIfNecessary:true) === original,"Polling replaced selected cell")
        print("PASS eight reordered but unchanged snapshots preserve table views and selection")
        var updated = tabs
        for i in updated.indices { updated[i].browserSession = "session-two";updated[i].windowTitle = "Updated source tooltip" }
        controller.setTabs(updated,currentWindowID:"refresh-test")
        precondition(table.fullReloads == full && table.partialReloads == partial,"Action-only metadata caused redraw")
        precondition(controller.selectedTab?.browserSession == "session-two","Unchanged display kept stale activation metadata")
        print("PASS new session and tooltip metadata update actions without redrawing rows")
        updated[0].windowNumber = 2
        controller.setTabs(updated,currentWindowID:"refresh-test")
        precondition(table.fullReloads == full && table.partialReloads == partial+1,"Visible single-row update reloaded the entire table")
        print("PASS one visible row change uses partial table reload")
        let scroll = table.enclosingScrollView!
        scroll.contentView.scroll(to:NSPoint(x:0,y:300));scroll.reflectScrolledClipView(scroll.contentView)
        let top = table.row(at:NSPoint(x:0,y:scroll.contentView.bounds.minY))
        let before = table.view(atColumn:0,row:top,makeIfNecessary:true)?.accessibilityLabel()
        var inserted = updated[0];inserted.tabID = "new";inserted.title = "AAA inserted";inserted.isActive = false;inserted.windowNumber = 1
        controller.setTabs(updated+[inserted],currentWindowID:"refresh-test")
        let newTop = table.row(at:NSPoint(x:0,y:scroll.contentView.bounds.minY))
        let after = table.view(atColumn:0,row:newTop,makeIfNecessary:true)?.accessibilityLabel()
        precondition(before != nil && before == after,"Insertions above the viewport lost the visible anchor")
        print("PASS a real insertion preserves the visible scroll anchor")
        print("4 offscreen AppKit refresh checks passed; no windows shown or browser data used.")
    }
}
