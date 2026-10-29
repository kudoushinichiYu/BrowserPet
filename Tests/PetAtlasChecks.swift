import AppKit
import CryptoKit

@main struct PetAtlasChecks {
    static func main() throws {
        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let source = root.appendingPathComponent("Resources/pet-atlas.png")
        let layoutURL = root.appendingPathComponent("Resources/pet-atlas-frames.json")
        let data = try Data(contentsOf:layoutURL)
        let json = try JSONSerialization.jsonObject(with:data) as! [String:Any]
        let sha = SHA256.hash(data:try Data(contentsOf:source)).map { String(format:"%02x",$0) }.joined()
        precondition(json["sourceSHA256"] as? String == sha,"Geometry must match the original, unedited PNG")
        let atlas = PetAtlas(imageURL:source,layoutURL:layoutURL)
        let expected = [8,7,7,7,8,8,8,8,8]
        let width = 160,height = 174
        let context = CGContext(data:nil,width:8*width,height:9*height,bitsPerComponent:8,bytesPerRow:8*width*4,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        // A light checkerboard makes transparent-edge leakage visible in the runtime contact sheet.
        for y in stride(from:0,to:9*height,by:16) {
            for x in stride(from:0,to:8*width,by:16) {
                let shade:CGFloat = (x/16+y/16)%2 == 0 ? 0.94 : 0.87
                context.setFillColor(CGColor(gray:shade,alpha:1));context.fill(CGRect(x:x,y:y,width:16,height:16))
            }
        }
        var frameCount = 0
        for row in 0..<9 {
            precondition(atlas.count(row:row) == expected[row],"Animation frame count changed")
            for index in 0..<expected[row] {
                guard let image = atlas.cgImage(row:row,frame:index) else { fatalError("Missing frame \(row):\(index)") }
                precondition(image.width == width && image.height == height,"All states need a shared anchor canvas")
                var rgba = [UInt8](repeating:0,count:width*height*4)
                rgba.withUnsafeMutableBytes { bytes in
                    let reader = CGContext(data:bytes.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                        space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
                    reader.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
                }
                let alpha = stride(from:3,to:rgba.count,by:4).map { rgba[$0] }
                precondition(alpha.filter { $0 >= 128 }.count > 6000,"A frame lost part of the main cat")
                for y in 0..<height {
                    for x in 0..<width where x < 2 || y < 2 || x >= width-2 || y >= height-2 {
                        precondition(alpha[y*width+x] == 0,"Cat or foreign fragment reaches a canvas edge")
                    }
                }
                // Independently check 8-connected opaque islands: only one cat may remain.
                var seen = Set<Int>(),largeIslands = 0
                for seed in 0..<alpha.count where alpha[seed] >= 128 && !seen.contains(seed) {
                    var queue = [seed],head = 0;seen.insert(seed)
                    while head < queue.count {
                        let pixel = queue[head],x = pixel%width,y = pixel/width;head += 1
                        for ny in max(0,y-1)...min(height-1,y+1) {
                            for nx in max(0,x-1)...min(width-1,x+1) {
                                let next = ny*width+nx
                                if alpha[next] >= 128 && seen.insert(next).inserted { queue.append(next) }
                            }
                        }
                    }
                    if queue.count >= 8 { largeIslands += 1 }
                }
                precondition(largeIslands == 1,"A disconnected piece leaked into frame \(row):\(index)")
                context.draw(image,in:CGRect(x:index*width,y:(8-row)*height,width:width,height:height))
                frameCount += 1
            }
            print("PASS row \(row): \(expected[row]) complete cats, no opaque foreign islands or edge clipping")
        }
        precondition(frameCount == 69)
        precondition(atlas.cgImage(row:-1,frame:0) == nil && atlas.cgImage(row:9,frame:0) == nil)
        let output = root.appendingPathComponent("output/validation/pet-atlas-cleaned-contact-sheet.png")
        let bitmap = NSBitmapImageRep(cgImage:context.makeImage()!)
        try bitmap.representation(using:.png,properties:[:])!.write(to:output)
        print("PASS original atlas SHA256 retained; all 69 runtime frames checked; invalid rows rejected")
        print("Runtime contact sheet: output/validation/pet-atlas-cleaned-contact-sheet.png")
    }
}
