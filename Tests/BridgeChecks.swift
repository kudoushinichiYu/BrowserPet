import Foundation
import Darwin

@main struct BridgeChecks {
    static func main() throws {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("bp-test-\(UUID().uuidString.prefix(8)).sock")
        let server = GroupBridgeServer(path:path), lock = NSLock(), arrived = DispatchSemaphore(value:0)
        var received: NativeGroupMessage?
        server.onMessage = { message in lock.lock();received=message;lock.unlock();arrived.signal() }
        guard server.start() else { fatalError("Could not bind private local test socket: \(String(cString:strerror(errno)))") }
        defer { server.stop() }
        let message = NativeGroupMessage(version:1,type:"snapshot",instanceID:UUID().uuidString,sequence:1,windowIDs:[11],groups:[.init(id:3,windowID:11,title:"原有分组",color:"blue",collapsed:false)],tabs:[.init(tabID:7,windowID:11,groupID:3)])
        let payload = try JSONEncoder().encode(message)
        guard GroupSocket.send(payload,path:path),arrived.wait(timeout:.now()+2) == .success else { fatalError("Local bridge failed to deliver and acknowledge data") }
        lock.lock(); let delivered = received; lock.unlock()
        guard delivered?.groups.first?.title == "原有分组",delivered?.tabs.first?.tabID == 7 else { fatalError("Bridge payload mismatch") }
        print("PASS real local socket transmits and acknowledges native group metadata")
        let attrs = try FileManager.default.attributesOfItem(atPath:path)
        guard (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600 else { fatalError("Socket must be owner-only") }
        print("PASS local group socket is restricted to its owner")
        guard !GroupSocket.send(Data("{\"version\":999}".utf8),path:path) else { fatalError("Invalid messages must not be accepted") }
        print("PASS malformed bridge messages rejected over real socket")
        let pipes = Pipe()
        let framed = try GroupSocket.frame(payload)
        // Fragmented prefix and payload exercise real stream framing, not JSON-only mocks.
        DispatchQueue.global().async {
            for part in [framed.prefix(2),framed.dropFirst(2).prefix(3),framed.dropFirst(5)] { try? pipes.fileHandleForWriting.write(contentsOf:part) }
            try? pipes.fileHandleForWriting.close()
        }
        guard try GroupSocket.readFrame(from:pipes.fileHandleForReading.fileDescriptor) == payload else { fatalError("Fragmented framing mismatch") }
        print("PASS native message framing survives fragmented reads")
        guard !GroupSocket.send(payload,path:path+"-absent") else { fatalError("Missing app must not report connected") }
        print("PASS absent app reports disconnected without launching UI")
        print("5 bridge integration checks passed. No browser data used.")
    }
}
