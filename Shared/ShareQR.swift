import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

enum ShareQR {
    static func storeURL(appID: String) -> URL? {
        guard !appID.isEmpty, appID.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return URL(string: "https://apps.apple.com/app/id" + appID)
    }

    static func image(for string: String) -> CGImage? {
        let generator = CIFilter.qrCodeGenerator()
        generator.message = Data(string.utf8)
        generator.correctionLevel = "M"
        guard let raw = generator.outputImage else { return nil }
        let codeBounds = raw.extent.insetBy(dx: -4, dy: -4)
        let padded = raw.composited(over: CIImage(color: .white).cropped(to: codeBounds)).cropped(to: codeBounds)
        let scaled = padded.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
