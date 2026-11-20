import UIKit
import UniformTypeIdentifiers

/// Makes a picture ready for the media library before it is uploaded, as the web does in the browser:
/// photos are made no bigger than 2560 pixels on their longest side, JPEGs are always re-saved (which
/// drops the camera's hidden details, such as where the photo was taken), and iPhone photos (HEIC)
/// become JPEGs. GIFs (animation) and SVGs go up as they are; the server checks what every file really is.
enum CMSImagePrep {
    struct Prepared: Equatable {
        let file: EngageFile
        let width: Int?
        let height: Int?
    }

    enum Problem: Error, Equatable {
        case notAnImage(String)
        case tooLarge(String)

        var message: String {
            switch self {
            case .notAnImage(let name): "“\(name)” isn’t a picture. Choose a JPEG, PNG, WebP, GIF or SVG file, or a photo."
            case .tooLarge(let name): "“\(name)” is larger than 8 MB. Make it smaller and try again."
            }
        }
    }

    static func prepare(_ data: Data, type: UTType?, name: String) throws -> Prepared {
        let base = ((name as NSString).deletingPathExtension).trimmedOrNil ?? "image"
        let kind = type ?? UTType(filenameExtension: (name as NSString).pathExtension)
        if let kind, kind.conforms(to: .svg) || kind.conforms(to: .gif) {
            guard data.count <= CMSMedia.maxBytes else { throw Problem.tooLarge(name) }
            let image = kind.conforms(to: .gif) ? UIImage(data: data) : nil
            return Prepared(file: EngageFile(name: name, data: data, mimeType: kind.preferredMIMEType ?? "image/svg+xml"),
                            width: image.map { Int($0.size.width * $0.scale) }, height: image.map { Int($0.size.height * $0.scale) })
        }
        guard let image = UIImage(data: data) else { throw Problem.notAnImage(name) }
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let scale = min(1, CMSMedia.maxEdge / max(pixels.width, pixels.height, 1))
        let isPNG = kind?.conforms(to: .png) == true
        let isJPEG = kind?.conforms(to: .jpeg) == true
        // A small PNG or WebP goes up untouched; anything else is redrawn.
        if scale >= 1, !isJPEG, kind?.conforms(to: .png) == true || kind?.conforms(to: .webP) == true {
            guard data.count <= CMSMedia.maxBytes else { throw Problem.tooLarge(name) }
            return Prepared(file: EngageFile(name: name, data: data, mimeType: kind?.preferredMIMEType ?? "image/png"),
                            width: Int(pixels.width), height: Int(pixels.height))
        }
        let size = CGSize(width: max(1, (pixels.width * scale).rounded()), height: max(1, (pixels.height * scale).rounded()))
        let redrawn = render(image, size: size)
        let out: Data?
        let file: String
        if isPNG {
            out = redrawn.pngData()
            file = base + ".png"
        } else {
            out = redrawn.jpegData(compressionQuality: 0.86)
            file = base + ".jpg"
        }
        guard let out else { throw Problem.notAnImage(name) }
        guard out.count <= CMSMedia.maxBytes else { throw Problem.tooLarge(name) }
        return Prepared(file: EngageFile(name: file, data: out, mimeType: isPNG ? "image/png" : "image/jpeg"),
                        width: Int(size.width), height: Int(size.height))
    }

    /// Draws an image at an exact pixel size, upright.
    static func render(_ image: UIImage, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// The picture turned by quarter turns clockwise, upright and at scale 1 (points are pixels).
    static func rotated(_ image: UIImage, quarterTurns: Int) -> UIImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let size = turns % 2 == 0 ? pixels : CGSize(width: pixels.height, height: pixels.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            cg.translateBy(x: size.width / 2, y: size.height / 2)
            cg.rotate(by: CGFloat(turns) * .pi / 2)
            image.draw(in: CGRect(x: -pixels.width / 2, y: -pixels.height / 2, width: pixels.width, height: pixels.height))
        }
    }

    /// Cuts `area` (pixels of `image`) out and scales it to `width` pixels wide.
    static func crop(_ image: UIImage, area: CGRect, width: Int) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        let clipped = area.integral.intersection(bounds)
        guard !clipped.isEmpty, let piece = cg.cropping(to: clipped) else { return nil }
        let outWidth = max(1, width)
        let outHeight = max(1, Int((Double(outWidth) * clipped.height / clipped.width).rounded()))
        return render(UIImage(cgImage: piece), size: CGSize(width: outWidth, height: outHeight))
    }

    /// The type an edited copy is saved as: JPEG stays JPEG, PNG stays PNG, everything else becomes PNG.
    static func editedType(for mime: String?) -> (mime: String, ext: String) {
        mime == "image/jpeg" ? ("image/jpeg", "jpg") : ("image/png", "png")
    }

    static func encode(_ image: UIImage, mime: String) -> Data? {
        mime == "image/jpeg" ? image.jpegData(compressionQuality: 0.9) : image.pngData()
    }
}

/// The crop shapes the web editor offers.
enum CMSCropShape: String, CaseIterable, Identifiable {
    case original, square, fourThree, wide, social
    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: "Original shape"
        case .square: "Square"
        case .fourThree: "4:3"
        case .wide: "Wide 16:9"
        case .social: "Featured / social 1.91:1"
        }
    }

    /// Width ÷ height (nil: the picture's own).
    var ratio: CGFloat? {
        switch self {
        case .original: nil
        case .square: 1
        case .fourThree: 4.0 / 3.0
        case .wide: 16.0 / 9.0
        case .social: 1200.0 / 630.0
        }
    }
}

/// Where the crop frame sits on a picture: pure maths, so it can be tested.
struct CMSCropGeometry: Equatable {
    /// The (turned) picture's size in pixels.
    var image: CGSize
    /// The crop frame's size on screen.
    var frame: CGSize
    /// 1…4: how far the picture is zoomed in beyond just filling the frame.
    var zoom: CGFloat
    /// How far the picture's centre is moved from the frame's centre, on screen.
    var offset: CGSize

    /// Screen points per picture pixel.
    var scale: CGFloat {
        guard image.width > 0, image.height > 0 else { return 1 }
        return max(frame.width / image.width, frame.height / image.height) * zoom
    }

    var displayed: CGSize { CGSize(width: image.width * scale, height: image.height * scale) }

    /// The offset kept so the picture always covers the frame.
    func clamped(_ proposed: CGSize) -> CGSize {
        let maxX = max(0, (displayed.width - frame.width) / 2)
        let maxY = max(0, (displayed.height - frame.height) / 2)
        return CGSize(width: min(max(proposed.width, -maxX), maxX), height: min(max(proposed.height, -maxY), maxY))
    }

    /// The part of the picture inside the frame, in picture pixels.
    var area: CGRect {
        let x = (displayed.width - frame.width) / 2 - offset.width
        let y = (displayed.height - frame.height) / 2 - offset.height
        return CGRect(x: x / scale, y: y / scale, width: frame.width / scale, height: frame.height / scale)
    }

    /// A frame of the given shape that fits in `space`.
    static func frame(ratio: CGFloat, in space: CGSize) -> CGSize {
        guard ratio > 0, space.width > 0, space.height > 0 else { return .zero }
        if space.width / space.height > ratio { return CGSize(width: space.height * ratio, height: space.height) }
        return CGSize(width: space.width, height: space.width / ratio)
    }
}
