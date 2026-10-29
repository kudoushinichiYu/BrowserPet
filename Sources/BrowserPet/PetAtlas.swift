import AppKit

struct PetAtlasLayout: Decodable {
    struct Row: Decodable {
        let state: String
        let baselineY: Int
        let frames: [[Int]]
    }
    let version: Int
    let sourceWidth: Int
    let sourceHeight: Int
    let canvasWidth: Int
    let canvasHeight: Int
    let rows: [Row]
}

final class PetAtlas {
    private let sheet: CGImage?
    private let layout: PetAtlasLayout?
    private var cache: [String:CGImage] = [:]

    init(imageURL:URL,layoutURL:URL) {
        let image = NSImage(contentsOf:imageURL)
        sheet = image?.cgImage(forProposedRect:nil,context:nil,hints:nil)
        if let data = try? Data(contentsOf:layoutURL),let parsed = try? JSONDecoder().decode(PetAtlasLayout.self,from:data),
           parsed.version == 1,parsed.sourceWidth == sheet?.width,parsed.sourceHeight == sheet?.height,
           parsed.canvasWidth > 0,parsed.canvasHeight > 0 {
            layout = parsed
        } else { layout = nil }
    }
    func count(row:Int) -> Int {
        guard let layout,layout.rows.indices.contains(row) else { return 1 }
        return layout.rows[row].frames.count
    }
    func image(row:Int,frame:Int) -> NSImage? {
        guard let frame = cgImage(row:row,frame:frame) else { return nil }
        return NSImage(cgImage:frame,size:NSSize(width:frame.width,height:frame.height))
    }
    func cgImage(row:Int,frame:Int) -> CGImage? {
        guard let sheet,let layout,layout.rows.indices.contains(row) else { return nil }
        let info = layout.rows[row]
        guard !info.frames.isEmpty else { return nil }
        let index = ((frame % info.frames.count)+info.frames.count) % info.frames.count
        let key = "\(row):\(index)"
        if let cached = cache[key] { return cached }
        let values = info.frames[index]
        guard values.count == 4 else { return nil }
        let rect = CGRect(x:values[0],y:values[1],width:values[2],height:values[3])
        guard rect.minX >= 0,rect.minY >= 0,rect.maxX <= CGFloat(sheet.width),rect.maxY <= CGFloat(sheet.height),
              rect.width > 0,rect.height > 0,rect.width <= CGFloat(layout.canvasWidth),
              let source = sheet.cropping(to:rect),let clean = Self.isolateCat(source),
              let canvas = CGContext(data:nil,width:layout.canvasWidth,height:layout.canvasHeight,bitsPerComponent:8,
                bytesPerRow:layout.canvasWidth*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Preserve vertical jump/run motion, while centering each cat on one shared canvas.
        let y = CGFloat(info.baselineY)-rect.maxY
        guard y >= 0,y+rect.height <= CGFloat(layout.canvasHeight) else { return nil }
        canvas.interpolationQuality = .none
        canvas.draw(clean,in:CGRect(x:floor((CGFloat(layout.canvasWidth)-rect.width)/2),y:y,width:rect.width,height:rect.height))
        guard let rendered = canvas.makeImage() else { return nil }
        cache[key] = rendered; return rendered
    }

    /// Preserve the complete main silhouette and a one-pixel antialiased edge;
    /// disconnected marks or pieces of neighboring sprites cannot leak into the frame.
    private static func isolateCat(_ image:CGImage) -> CGImage? {
        let width = image.width,height = image.height,total = width*height
        var pixels = [UInt8](repeating:0,count:total*4)
        let decoded = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data:bytes.baseAddress,width:width,height:height,bitsPerComponent:8,
                bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image,in:CGRect(x:0,y:0,width:width,height:height)); return true
        }
        guard decoded else { return nil }
        var visited = [Bool](repeating:false,count:total),largest: [Int] = []
        for seed in 0..<total where !visited[seed] && pixels[seed*4+3] >= 32 {
            var queue = [seed],head = 0; visited[seed] = true
            while head < queue.count {
                let pixel = queue[head],x = pixel % width,y = pixel / width; head += 1
                var neighbors: [Int] = []
                if x > 0 { neighbors.append(pixel-1) }; if x+1 < width { neighbors.append(pixel+1) }
                if y > 0 { neighbors.append(pixel-width) }; if y+1 < height { neighbors.append(pixel+width) }
                for next in neighbors where !visited[next] && pixels[next*4+3] >= 32 {
                    visited[next] = true; queue.append(next)
                }
            }
            if queue.count > largest.count { largest = queue }
        }
        guard largest.count > 1000 else { return nil }
        var keep = [Bool](repeating:false,count:total)
        for pixel in largest {
            let x = pixel % width,y = pixel / width
            for ny in max(0,y-1)...min(height-1,y+1) {
                for nx in max(0,x-1)...min(width-1,x+1) { keep[ny*width+nx] = true }
            }
        }
        for pixel in 0..<total where !keep[pixel] {
            for channel in 0..<4 { pixels[pixel*4+channel] = 0 }
        }
        guard let provider = CGDataProvider(data:Data(pixels) as CFData) else { return nil }
        return CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent)
    }
}
