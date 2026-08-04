// Reproduce the mosaic defect with a decisive fixture, before changing any code.
// Canvas 8x8: top half pure red, bottom half pure blue (in annotation space, top-left origin).
// Mosaic the TOP band. If the mosaic'd band comes out blue-ish, the crop is mirrored.
import AppKit
import CoreGraphics

func makeContext(width: Int, height: Int) -> CGContext? {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
}

let W = 80, H = 80
let ctx = makeContext(width: W, height: H)!
// context space: bottom-left origin. Red on TOP half (y 40..80), blue on bottom (0..40).
ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
ctx.fill(CGRect(x: 0, y: 40, width: 80, height: 40))
ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: 80, height: 40))

// Replicate AnnotationRenderer.draw + drawMosaic verbatim for a mosaic over the TOP band
// (annotation space rect y=0..40 == red).
ctx.saveGState()
ctx.translateBy(x: 0, y: CGFloat(H))
ctx.scaleBy(x: 1, y: -1)

let r = CGRect(x: 0, y: 0, width: 80, height: 40)  // annotation space: TOP band (red)
let canvasSize = CGSize(width: W, height: H)
let snapshot = ctx.makeImage()!
let flipped = CGRect(x: r.origin.x, y: canvasSize.height - r.origin.y - r.height,
                     width: r.width, height: r.height)
let region = snapshot.cropping(to: flipped)!

let block: CGFloat = 16
let smallW = max(1, Int((r.width / block).rounded(.down)))
let smallH = max(1, Int((r.height / block).rounded(.down)))
let smallCtx = makeContext(width: smallW, height: smallH)!
smallCtx.interpolationQuality = .medium
smallCtx.draw(region, in: CGRect(x: 0, y: 0, width: smallW, height: smallH))
let small = smallCtx.makeImage()!

ctx.saveGState()
ctx.interpolationQuality = .none
ctx.translateBy(x: r.midX, y: r.midY)
ctx.scaleBy(x: 1, y: -1)
ctx.draw(small, in: CGRect(x: -r.width / 2, y: -r.height / 2, width: r.width, height: r.height))
ctx.restoreGState()
ctx.restoreGState()

// Sample the mosaic'd top band (annotation y=0..40 → context y=40..80 → row 0..40).
let out = ctx.makeImage()!
let data = out.dataProvider!.data! as Data
let bpr = out.bytesPerRow
func rgb(row: Int, col: Int) -> (Int, Int, Int) {
    let o = row * bpr + col * 4
    return (Int(data[o]), Int(data[o+1]), Int(data[o+2]))
}
let topSample = rgb(row: 10, col: 40)     // inside the mosaic'd band — SHOULD be red
let bottomSample = rgb(row: 70, col: 40)  // untouched bottom — should stay blue
print("mosaic'd top band sample: \(topSample)  (expected red ~(255,0,0))")
print("untouched bottom sample:  \(bottomSample)  (expected blue ~(0,0,255))")
if topSample.2 > topSample.0 {
    print("CONFIRMED: the mosaic band shows BLUE — the crop is vertically mirrored.")
} else {
    print("NOT REPRODUCED: the band is red; mirror hypothesis is wrong.")
}
