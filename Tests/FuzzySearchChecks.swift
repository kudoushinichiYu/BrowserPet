import Foundation

@main struct FuzzySearchChecks {
    static func main() {
        var checks = 0
        func check(_ name:String,_ value:Bool) { precondition(value,name);checks += 1;print("PASS "+name) }
        func page(_ id:String,_ title:String,_ url:String = "https://example.test/") -> BrowserTab {
            BrowserTab(windowID:"same-window",tabID:id,title:title,url:url,windowTitle:"Synthetic",windowNumber:1,isActive:false)
        }
        func matches(_ query:String,_ tabs:[BrowserTab]) -> [String] {
            SearchEngine.groups(tabs:tabs,query:query,currentWindowID:nil,mode:.window).flatMap(\.tabs).map(\.tabID)
        }
        let diffusion = page("diffusion","Diffusion model survey","https://research.test/benchmark")
        let github = page("github","GitHub BrowserPet","https://github.com/example/BrowserPet")
        let chinese = page("chinese","项目周报","https://docs.test/project")
        check("ordered Latin abbreviation matches a compact title span",matches("dffsn",[diffusion]) == ["diffusion"])
        check("short abbreviation can match GitHub at the start of a word",matches("gh",[github]) == ["github"])
        check("word initials match across a long English title",matches("dms",[diffusion]) == ["diffusion"])
        check("English initials still require every letter in order",matches("prn",[page("notes","Product Review Notes")]) == ["notes"] && matches("pnr",[page("notes","Product Review Notes")]).isEmpty)
        check("two-letter scattered matches cannot span an entire title",matches("dq",[page("noise","Deep research platform status question")]).isEmpty)
        check("adjacent transposition is tolerated",matches("githbu",[github]) == ["github"])
        check("single missing character is tolerated",matches("difusion",[diffusion]) == ["diffusion"])
        check("single added character is tolerated",matches("difffusion",[diffusion]) == ["diffusion"])
        check("single wrong character is tolerated in a whole Latin word",matches("githup",[github]) == ["github"])
        check("two typos are allowed only in sufficiently long words",matches("dfifusoin",[diffusion]) == ["diffusion"])
        check("three edits do not match a nine-letter word",matches("dfffusxxn",[diffusion]).isEmpty)
        check("domain typo can match the host without matching URL parameters",matches("githbu.com",[page("host","Repository","https://github.com/example")]) == ["host"])
        check("all terms remain required when one term is fuzzy",matches("diffusoin benchmark",[diffusion,page("other","Diffusion notes")]) == ["diffusion"])
        check("a nonmatching extra term is never silently discarded",matches("githbu bananaquantum",[github]).isEmpty)
        check("literal whole-title matches outrank fuzzy matches even when the fuzzy title is alphabetical first",matches("githbu",[github,page("exact","githbu")]) == ["exact","github"])
        check("literal URL matches outrank fuzzy title matches",matches("githbu",[github,page("url","Other","https://literal.test/githbu")]) == ["url","github"])
        check("Chinese initials match the title",matches("xmzb",[chinese]) == ["chinese"])
        check("Chinese full and partial pinyin match",matches("xiangmuzhoubao",[chinese]) == ["chinese"] && matches("xiangmu",[chinese]) == ["chinese"])
        check("multiple pinyin terms may match different parts of a title",matches("xiang bao",[chinese]) == ["chinese"])
        check("width and case normalization also apply to pinyin initials",matches("ＸＭＺＢ",[chinese]) == ["chinese"])
        check("Chinese ordered omissions match without changing order",matches("项周报",[chinese]) == ["chinese"] && matches("报周项",[chinese]).isEmpty)
        check("one-character input is literal and numeric paper IDs are not fuzzed",matches("想",[chinese]).isEmpty && matches("2513",[page("paper","Paper 2510.12330")]).isEmpty)
        check("English and Chinese semantic synonyms are not invented",matches("diffusion",[page("cn","扩散模型研究")]).isEmpty)
        var revised = chinese;revised.title = "模型评测"
        check("title changes do not retain stale phonetic matches",matches("xmzb",[revised]).isEmpty)
        check("fuzzy matching does not merge duplicate browser tabs",matches("githbu",[github,page("copy",github.title,github.url)]).count == 2)
        let many = (0..<2000).map { page(String($0),"项目周报 第\($0)期","https://docs.test/\($0)") }
        let coldStart = Date();let cold = matches("xmzb",many);let coldTime = Date().timeIntervalSince(coldStart)
        check("2000 distinct Chinese titles support initials within two seconds",cold.count == 2000 && coldTime < 2)
        let warmStart = Date();let warm = matches("xiangmu",many);let warmTime = Date().timeIntervalSince(warmStart)
        check("cached phonetics keep repeated 2000-tab search within one second",warm.count == 2000 && warmTime < 1)
        let latin = (0..<2000).map { page(String($0),"Diffusion model \($0)","https://research.test/\($0)") }
        let typoStart = Date();let typo = matches("diffusoin",latin);let typoTime = Date().timeIntervalSince(typoStart)
        check("2000-tab typo search remains within two seconds",typo.count == 2000 && typoTime < 2)
        print("\(checks) fuzzy-search checks passed. 2000 tabs: cold pinyin \(Int(coldTime*1000)) ms, cached pinyin \(Int(warmTime*1000)) ms, typos \(Int(typoTime*1000)) ms.")
    }
}
