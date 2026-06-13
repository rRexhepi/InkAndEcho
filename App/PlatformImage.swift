import SwiftUI

// Catalyst exposes both UIKit and AppKit but `NSImage(data:)` is
// unavailable there — `canImport(AppKit)` alone would route us into the
// AppKit branch and break the build. Prefer UIKit when present, which
// covers iOS, iPadOS, and Mac Catalyst.
#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif

extension Image {
    init?(platformData data: Data) {
        guard let image = PlatformImage(data: data) else { return nil }
        #if canImport(UIKit)
        self.init(uiImage: image)
        #elseif canImport(AppKit)
        self.init(nsImage: image)
        #endif
    }
}

import ImageIO
import UniformTypeIdentifiers

/// Downsample cover bytes before persisting them. Imported covers arrive at
/// print resolution (several MB); the library grid renders them at ~200pt.
/// ImageIO decodes straight to the thumbnail without inflating the full
/// bitmap. Returns the original data when decoding fails (store something
/// rather than nothing) or when it's already small.
func downsampledCoverData(_ data: Data, maxEdge: CGFloat = 600) -> Data {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return data }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxEdge * 2, // 2x for Retina
    ]
    guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        return data
    }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
        return data
    }
    CGImageDestinationAddImage(dest, thumb, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return data }
    let result = out as Data
    // A tiny original (e.g. an already-small JPEG) can re-encode larger.
    return result.count < data.count ? result : data
}
