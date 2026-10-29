import Foundation
import Security

enum LocalSetup {
    static var root:URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("BrowserPet",isDirectory:true)
    }
    private static func privateDirectory(_ url:URL) throws {
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:url.path)
    }
    private static func writePrivate(_ data:Data,to url:URL) throws {
        if (try? Data(contentsOf:url)) != data { try data.write(to:url,options:.atomic) }
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    static func pairing(at root:URL = LocalSetup.root,legacy:URL? = nil) throws -> SafariPairing {
        try privateDirectory(root)
        let file = root.appendingPathComponent("safari-pairing.json")
        let value:SafariPairing
        if FileManager.default.fileExists(atPath:file.path) {
            value = try JSONDecoder().decode(SafariPairing.self,from:Data(contentsOf:file))
        } else if let legacy,FileManager.default.fileExists(atPath:legacy.path) {
            value = try JSONDecoder().decode(SafariPairing.self,from:Data(contentsOf:legacy))
        } else {
            var bytes = [UInt8](repeating:0,count:32)
            guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes) == errSecSuccess else { throw CocoaError(.fileWriteUnknown) }
            value = SafariPairing(port:49731,token:bytes.map { String(format:"%02x",$0) }.joined())
        }
        guard value.port == 49731,value.token.count == 64,value.token.allSatisfy({ $0.isHexDigit }) else { throw GroupProtocolError.invalid }
        try writePrivate(try JSONEncoder().encode(value),to:file)
        return value
    }
    static func safariHelper(resources:URL,at root:URL = LocalSetup.root,pairing:SafariPairing) throws -> URL {
        try privateDirectory(root)
        let folder = root.appendingPathComponent("SafariHelper",isDirectory:true)
        try privateDirectory(folder)
        for name in ["manifest.json","protocol.js","background.js"] {
            let data = try Data(contentsOf:resources.appendingPathComponent("safari-tabs/"+name))
            try writePrivate(data,to:folder.appendingPathComponent(name))
        }
        let settings = ["endpoint":"http://127.0.0.1:\(pairing.port)/v1/safari/sync","token":pairing.token]
        let json = try JSONSerialization.data(withJSONObject:settings,options:.sortedKeys)
        let script = "const BROWSERPET_PAIRING = Object.freeze("+String(decoding:json,as:UTF8.self)+");\n"
        try writePrivate(Data(script.utf8),to:folder.appendingPathComponent("config.js"))
        return folder
    }
    static func chromeHostManifest(app:URL) throws -> [String:Any] {
        let resources = app.appendingPathComponent("Contents/Resources")
        let data = try Data(contentsOf:resources.appendingPathComponent("group-bridge-config.json"))
        guard let config = try JSONSerialization.jsonObject(with:data) as? [String:String],
              let name = config["hostName"],let origin = config["extensionOrigin"] else { throw GroupProtocolError.invalid }
        let executable = resources.appendingPathComponent("group-native-host")
        guard FileManager.default.isExecutableFile(atPath:executable.path) else { throw CocoaError(.fileNoSuchFile) }
        return ["name":name,"description":"BrowserPet local read-only tab-group bridge","path":executable.path,
                "type":"stdio","allowed_origins":[origin]]
    }
    static func registerChromeHost(app:URL,directory:URL? = nil) throws {
        let manifest = try chromeHostManifest(app:app)
        let hosts = directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts",isDirectory:true)
        try FileManager.default.createDirectory(at:hosts,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let target = hosts.appendingPathComponent("local.browserpet.groups.json")
        if FileManager.default.fileExists(atPath:target.path) {
            let existing = try JSONSerialization.jsonObject(with:Data(contentsOf:target)) as? [String:Any]
            guard existing?["name"] as? String == manifest["name"] as? String,
                  existing?["allowed_origins"] as? [String] == manifest["allowed_origins"] as? [String] else { throw GroupProtocolError.invalid }
        }
        try writePrivate(try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]),to:target)
    }
}
