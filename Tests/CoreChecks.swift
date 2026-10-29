import Foundation

@main struct CoreChecks {
    static func main() throws {
        var count = 0
        func check(_ name: String,_ condition: @autoclosure () -> Bool) {
            guard condition() else { fatalError("FAIL: \(name)") }
            count += 1; print("PASS \(name)")
        }
        let groups = SearchEngine.groups(tabs: DemoData.tabs,query: "项目 周报",currentWindowID: "101")
        check("all keywords required",groups.flatMap(\.tabs).count == 3)
        check("same-title pages remain distinct",Set(groups.flatMap(\.tabs).map(\.id)).count == 3)
        check("nonmatching title excluded",!groups.flatMap(\.tabs).contains { $0.title == "产品方案" })
        check("terms match across title and URL",SearchEngine.groups(tabs: DemoData.tabs,query: "项目 REVIEW",currentWindowID: nil).flatMap(\.tabs).map(\.tabID) == ["2"])
        var tabs = Array(DemoData.tabs.prefix(3))
        tabs[0].title = "其他"; tabs[0].url = "https://docs.example.com/项目周报"
        check("title outranks URL",SearchEngine.groups(tabs: tabs,query: "项目",currentWindowID: "101").flatMap(\.tabs).first?.tabID == "2")
        check("current window breaks equal-match ties",SearchEngine.groups(tabs: DemoData.tabs,query: "项目周报",currentWindowID: "102").flatMap(\.tabs).first?.tabID == "6")
        check("case, whitespace and width normalization",SearchEngine.groups(tabs: DemoData.tabs,query: "  ＧＩＴＨＵＢ\n browserpet  ",currentWindowID: nil).flatMap(\.tabs).map(\.tabID) == ["4"])
        let all = SearchEngine.groups(tabs: DemoData.tabs,query: " \t ",currentWindowID: "101")
        check("empty query includes all pages",all.flatMap(\.tabs).count == 6)
        check("exact-host domain grouping",Set(all.map(\.domain)) == ["docs.example.com","github.com","developer.apple.com"])
        var special = DemoData.tabs[0]
        special.title = "周报\n\"引号\"\t🐈"; special.url = "https://example.com/?a=1&b=%22"
        let data = try JSONEncoder().encode(special)
        let decoded = try JSONDecoder().decode(BrowserTab.self,from: data)
        check("special characters round-trip",special == decoded)
        special.url = "file:///private/tmp/test.html"; check("file URLs group locally",special.domain == "本地文件")
        let many = (0..<2000).map { i -> BrowserTab in var tab=DemoData.tabs[i % DemoData.tabs.count]; tab.tabID=String(i); return tab }
        let start = Date()
        let matches = SearchEngine.groups(tabs: many,query: "项目 周报",currentWindowID: "101").flatMap(\.tabs)
        let elapsed = Date().timeIntervalSince(start)
        check("2000-tab snapshot returns expected matches",matches.count == 1001)
        check("2000-tab in-memory search under 2 seconds",elapsed < 2)
        var identity = BrowserSessionIdentity()
        let original = identity.observe(123)
        check("transient missing process query does not falsely restart session",identity.observe(nil) == original && identity.observe(123) == original)
        let replacement = identity.observe(456)
        check("known replacement process invalidates old snapshot",replacement != original)
        identity.invalidate()
        check("explicit termination invalidates even if PID is reused",identity.observe(456) != replacement)
        var organized = DemoData.tabs
        let native = NativeTabGroup(key:"manual-project",title:"我的项目",color:"purple",collapsed:true)
        organized[0].nativeGroup = native; organized[4].nativeGroup = native
        let automatic = SearchEngine.groups(tabs:organized,query:"",currentWindowID:"101",mode:.automatic)
        check("original browser groups take precedence",automatic.first?.domain == "我的项目" && automatic.first?.isNative == true)
        check("manual cross-site group is not split by purpose",automatic.first?.tabs.count == 2)
        check("native color and collapse state retained",automatic.first?.color == "purple" && automatic.first?.collapsed == true)
        check("ungrouped pages receive purpose classification",automatic.contains { $0.domain == "代码与开发" && !$0.isNative })
        check("automatic grouping does not lose or deduplicate tabs",automatic.flatMap(\.tabs).count == organized.count)
        let windows = SearchEngine.groups(tabs:organized,query:"",currentWindowID:nil,mode:.window)
        check("window view keeps original window boundaries",windows.count == 3 && windows.allSatisfy { Set($0.tabs.map(\.windowID)).count == 1 })
        var paper = DemoData.tabs[0]; paper.url = "https://arxiv.org/abs/2501.12345"; paper.tabID = "7001"
        var htmlPaper = paper; htmlPaper.url = "https://ar5iv.labs.arxiv.org/html/2501.12345"; htmlPaper.tabID = "7002"
        check("arxiv entries share a purpose",SearchEngine.purpose(paper).key == SearchEngine.purpose(htmlPaper).key)
        check("site view merges arxiv html and pdf entry points",SearchEngine.groups(tabs:[paper,htmlPaper],query:"",currentWindowID:nil,mode:.site).count == 1)
        var unknown = paper; unknown.url = "https://unknown.example/invoice.pdf"
        check("unknown pdf is not guessed to be a research paper",SearchEngine.purpose(unknown).key == "other")
        let ownerA = "00000000-0000-0000-0000-000000000001", ownerB = "00000000-0000-0000-0000-000000000002"
        let time = Date(timeIntervalSince1970:1000)
        var payload = NativeGroupMessage(version:1,type:"snapshot",instanceID:ownerA,sequence:1,windowIDs:[101],groups:[.init(id:42,windowID:101,title:"原生组",color:"blue",collapsed:true)],tabs:[.init(tabID:1,windowID:101,groupID:42)])
        var repository = NativeGroupRepository(); try repository.apply(payload,now:time)
        let mapped = repository.snapshot(now:time)
        check("group IDs join to exact window and tab IDs",mapped.tabs["chrome:101:1"]?.title == "原生组" && mapped.tabs["chrome:102:1"] == nil)
        payload.sequence = 0; payload.groups[0].title = "过时组"; try repository.apply(payload,now:time)
        check("out-of-order snapshot cannot overwrite new groups",repository.snapshot(now:time).tabs["chrome:101:1"]?.title == "原生组")
        payload.instanceID = ownerB; payload.sequence = 1; payload.groups = []; payload.tabs = []
        try repository.apply(payload,now:time)
        check("worker restart with no groups clears old window assignments",repository.snapshot(now:time).tabs.isEmpty && repository.snapshot(now:time).connected)
        check("stale helper connection expires",!repository.snapshot(now:time.addingTimeInterval(46)).connected)
        payload.version = 999
        check("unsupported bridge protocol rejected",(try? payload.validate()) == nil)
        print("\(count) core checks passed; 2000-tab search \(String(format: "%.1f",elapsed*1000)) ms. No live browser data used.")
    }
}
