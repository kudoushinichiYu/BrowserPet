import Foundation
import Darwin

enum GroupSocket {
    static var path: String {
        // Both the Chrome helper and the UI app resolve the same per-user directory.
        var buffer = [CChar](repeating: 0,count: 4096)
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR,&buffer,buffer.count)
        let root = length > 0 ? String(cString: buffer) : NSTemporaryDirectory()
        return (root as NSString).appendingPathComponent("browserpet-groups-\(geteuid()).sock")
    }
    static func address(_ path: String) throws -> sockaddr_un {
        var value = sockaddr_un()
        value.sun_family = sa_family_t(AF_UNIX)
        value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)+[0]
        guard bytes.count <= MemoryLayout.size(ofValue: value.sun_path) else { throw GroupProtocolError.invalid }
        withUnsafeMutableBytes(of: &value.sun_path) { target in target.copyBytes(from: bytes) }
        return value
    }
    static func configure(_ fd: Int32) {
        var yes: Int32 = 1
        setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,socklen_t(MemoryLayout.size(ofValue:yes)))
        var timeout = timeval(tv_sec: 3,tv_usec: 0)
        setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout.size(ofValue:timeout)))
        setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,socklen_t(MemoryLayout.size(ofValue:timeout)))
    }
    static func write(_ data: Data,to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw GroupProtocolError.disconnected }
                offset += count
            }
        }
    }
    static func read(_ count: Int,from fd: Int32) throws -> Data {
        var data = Data(count:count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let n = Darwin.read(fd,bytes.baseAddress!.advanced(by:offset),count-offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw GroupProtocolError.disconnected }
                offset += n
            }
        }
        return data
    }
    static func frame(_ payload: Data) throws -> Data {
        guard !payload.isEmpty, payload.count <= 1024*1024 else { throw GroupProtocolError.invalid }
        var size = UInt32(payload.count).littleEndian
        var data = withUnsafeBytes(of:&size) { Data($0) }; data.append(payload); return data
    }
    static func readFrame(from fd: Int32) throws -> Data {
        let head = try read(4,from:fd)
        let count = head.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << (8*$1.offset)) }
        guard count > 0, count <= 1024*1024 else { throw GroupProtocolError.invalid }
        return try read(Int(count),from:fd)
    }
    static func send(_ payload: Data,path: String = GroupSocket.path) -> Bool {
        let fd = socket(AF_UNIX,SOCK_STREAM,0)
        guard fd >= 0 else { return false }; defer { Darwin.close(fd) }
        configure(fd)
        do {
            var value = try address(path)
            let result = withUnsafePointer(to:&value) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard result == 0 else { return false }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd,&uid,&gid) == 0, uid == geteuid() else { return false }
            try write(try frame(payload),to:fd)
            let reply = try readFrame(from:fd)
            return (try JSONSerialization.jsonObject(with:reply) as? [String:Bool])?["ok"] == true
        } catch { return false }
    }
}

final class GroupBridgeServer {
    private let path: String
    private var fd: Int32 = -1
    var onMessage: ((NativeGroupMessage) -> Void)?
    init(path: String = GroupSocket.path) { self.path = path }
    @discardableResult func start() -> Bool {
        guard fd < 0 else { return true }
        if FileManager.default.fileExists(atPath:path) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath:path),
                  attributes[.type] as? FileAttributeType == .typeSocket,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid() else { return false }
            let probe = socket(AF_UNIX,SOCK_STREAM,0)
            guard probe >= 0, var value = try? GroupSocket.address(path) else { if probe >= 0 { Darwin.close(probe) }; return false }
            let active = withUnsafePointer(to:&value) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.connect(probe,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            let error = errno; Darwin.close(probe)
            guard active != 0, error == ECONNREFUSED || error == ENOENT else { return false }
            guard unlink(path) == 0 || errno == ENOENT else { return false }
        }
        let listening = socket(AF_UNIX,SOCK_STREAM,0)
        guard listening >= 0, var value = try? GroupSocket.address(path) else { if listening >= 0 { Darwin.close(listening) }; return false }
        let bound = withUnsafePointer(to:&value) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(listening,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0 else { Darwin.close(listening); return false }
        guard chmod(path,0o600) == 0, listen(listening,8) == 0 else { Darwin.close(listening); unlink(path); return false }
        fd = listening
        DispatchQueue.global(qos:.utility).async { [weak self] in
            while let self, self.fd == listening {
                let client = accept(listening,nil,nil)
                if client < 0 { if errno == EINTR { continue }; break }
                GroupSocket.configure(client)
                var uid: uid_t = 0, gid: gid_t = 0
                if getpeereid(client,&uid,&gid) == 0, uid == geteuid() {
                    do {
                        let data = try GroupSocket.readFrame(from:client)
                        let message = try JSONDecoder().decode(NativeGroupMessage.self,from:data)
                        try message.validate(); self.onMessage?(message)
                        try GroupSocket.write(try GroupSocket.frame(Data("{\"ok\":true}".utf8)),to:client)
                    } catch { try? GroupSocket.write(try GroupSocket.frame(Data("{\"ok\":false}".utf8)),to:client) }
                }
                Darwin.close(client)
            }
        }
        return true
    }
    func stop() {
        let old = fd; fd = -1
        if old >= 0 { Darwin.shutdown(old,SHUT_RDWR); Darwin.close(old); unlink(path) }
    }
    deinit { stop() }
}

enum NativeGroupHost {
    static func run() {
        guard let data = try? Data(contentsOf:AppResources.url("group-bridge-config.json")),
              let config = try? JSONSerialization.jsonObject(with:data) as? [String:String],
              let origin = config["extensionOrigin"], CommandLine.arguments.contains(origin) else { return }
        var last: NativeGroupMessage?
        while let data = try? GroupSocket.readFrame(from:STDIN_FILENO) {
            var accepted = false
            if let message = try? JSONDecoder().decode(NativeGroupMessage.self,from:data), (try? message.validate()) != nil {
                accepted = GroupSocket.send(data); last = message
            }
            let reply = Data("{\"connected\":\(accepted ? "true" : "false")}".utf8)
            guard let frame = try? GroupSocket.frame(reply), (try? GroupSocket.write(frame,to:STDOUT_FILENO)) != nil else { break }
        }
        if var last { last.type = "disconnect"; last.sequence += 1; last.groups = []; last.tabs = []; if let data = try? JSONEncoder().encode(last) { _ = GroupSocket.send(data) } }
    }
}
