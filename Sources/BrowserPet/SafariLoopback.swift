import Foundation
import Darwin

struct SafariPairing: Codable {
    var port:UInt16
    var token:String
    static func load() -> SafariPairing? {
        try? LocalSetup.pairing(legacy:AppResources.url("safari-bridge-config.json"))
    }
}

/// Only the paired Safari extension can exchange metadata with this IPv4 loopback listener.
/// No website, wildcard CORS policy, remote interface, cookie or external endpoint is used.
final class SafariLoopback {
    private let pairing:SafariPairing
    private let adapter:SafariAdapter
    private var fd:Int32 = -1
    init(pairing:SafariPairing,adapter:SafariAdapter) { self.pairing = pairing;self.adapter = adapter }
    @discardableResult func start() -> Bool {
        let server = socket(AF_INET,SOCK_STREAM,0)
        guard server >= 0 else { return false }
        var reuse:Int32 = 1
        setsockopt(server,SOL_SOCKET,SO_REUSEADDR,&reuse,socklen_t(MemoryLayout.size(ofValue:reuse)))
        var address = sockaddr_in();address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET);address.sin_port = pairing.port.bigEndian
        address.sin_addr = in_addr(s_addr:inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { bind(server,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0,listen(server,8) == 0 else { Darwin.close(server);return false }
        fd = server
        DispatchQueue.global(qos:.utility).async { [weak self] in
            while let self,self.fd == server {
                let client = accept(server,nil,nil)
                if client < 0 { if errno == EINTR { continue };break }
                GroupSocket.configure(client)
                self.handle(client);Darwin.close(client)
            }
        }
        return true
    }
    private func handle(_ client:Int32) {
        var data = Data(),buffer = [UInt8](repeating:0,count:4096)
        let separator = Data([13,10,13,10])
        while data.range(of:separator) == nil {
            let n = Darwin.read(client,&buffer,buffer.count)
            guard n > 0,data.count+n <= 16384 else { return }
            data.append(contentsOf:buffer.prefix(n))
        }
        guard let boundary = data.range(of:separator),let header = String(data:data[..<boundary.lowerBound],encoding:.utf8) else { return }
        let lines = header.components(separatedBy:"\r\n")
        let request = (lines.first ?? "").split(separator:" ").map(String.init)
        guard request.count == 3,request[1] == "/v1/safari/sync",request[2] == "HTTP/1.1" else { reply(client,code:404);return }
        var headers: [String:String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of:":") else { reply(client,code:400);return }
            let key = line[..<colon].lowercased(),value = line[line.index(after:colon)...].trimmingCharacters(in:.whitespaces)
            guard headers[key] == nil else { reply(client,code:400);return };headers[key] = value
        }
        guard headers["host"] == "127.0.0.1:\(pairing.port)",headers["transfer-encoding"] == nil else { reply(client,code:403);return }
        let origin = headers["origin"]
        guard origin == nil || Self.allowedOrigin(origin!) else { reply(client,code:403);return }
        if request[0] == "OPTIONS" {
            guard origin != nil,headers["access-control-request-method"] == "POST" else { reply(client,code:403);return }
            reply(client,code:204,origin:origin);return
        }
        guard request[0] == "POST",Self.matches(headers["authorization"] ?? "", "Bearer "+pairing.token) else { reply(client,code:403);return }
        guard headers["content-type"]?.lowercased().hasPrefix("application/json") == true,
              let length = headers["content-length"].flatMap(Int.init),length > 0,length <= 4*1024*1024 else { reply(client,code:413,origin:origin);return }
        var body = Data(data[boundary.upperBound...])
        while body.count < length {
            let n = Darwin.read(client,&buffer,min(buffer.count,length-body.count))
            guard n > 0 else { return };body.append(contentsOf:buffer.prefix(n))
        }
        guard body.count == length,let message = try? JSONDecoder().decode(SafariExchange.self,from:body),
              let response = try? adapter.receive(message),let payload = try? JSONEncoder().encode(response) else { reply(client,code:400,origin:origin);return }
        reply(client,code:200,origin:origin,body:payload)
    }
    static func allowedOrigin(_ value:String) -> Bool {
        guard let url = URLComponents(string:value),url.scheme == "safari-web-extension",let host = url.host,
              UUID(uuidString:host) != nil,url.path.isEmpty,url.query == nil,url.fragment == nil,url.user == nil,url.password == nil,url.port == nil else { return false }
        return true
    }
    private static func matches(_ a:String,_ b:String) -> Bool {
        let x = Array(a.utf8),y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x,y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    private func reply(_ fd:Int32,code:Int,origin:String? = nil,body:Data = Data()) {
        var header = "HTTP/1.1 \(code) Response\r\nConnection: close\r\nCache-Control: no-store\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        if let origin { header += "Access-Control-Allow-Origin: \(origin)\r\nVary: Origin\r\nAccess-Control-Allow-Methods: POST, OPTIONS\r\nAccess-Control-Allow-Headers: Authorization, Content-Type\r\n" }
        header += "\r\n";var data = Data(header.utf8);data.append(body);try? GroupSocket.write(data,to:fd)
    }
    func stop() {
        let old = fd;fd = -1
        if old >= 0 { Darwin.shutdown(old,SHUT_RDWR);Darwin.close(old) }
        adapter.clear()
    }
    deinit { stop() }
}
