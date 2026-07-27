import CoreGraphics
import Foundation
import ImageIO

actor ApplicationIconLoader {
  static let shared = ApplicationIconLoader()

  private struct CacheKey: Hashable {
    let fileURL: URL
    let fileSize: Int
    let modificationDate: Date?
    let maximumPixelSize: Int
  }

  private let maximumEntryCount: Int
  private var cachedImages: [CacheKey: CGImage] = [:]
  private var accessOrder: [CacheKey] = []

  init(maximumEntryCount: Int = 96) {
    self.maximumEntryCount = max(1, maximumEntryCount)
  }

  func icon(at fileURL: URL, maximumPixelSize: Int) async -> CGImage? {
    guard !Task.isCancelled else { return nil }
    guard
      maximumPixelSize > 0,
      let cacheKey = cacheKey(
        for: fileURL,
        maximumPixelSize: maximumPixelSize
      )
    else {
      return nil
    }
    if let cachedImage = cachedImage(for: cacheKey) {
      return cachedImage
    }

    let decodeTask = Task.detached(priority: .utility) { () -> CGImage? in
      guard !Task.isCancelled else { return nil }
      return Self.downsample(
        imageAt: cacheKey.fileURL,
        maximumPixelSize: cacheKey.maximumPixelSize
      )
    }
    let image = await withTaskCancellationHandler {
      await decodeTask.value
    } onCancel: {
      decodeTask.cancel()
    }

    guard !Task.isCancelled, let image else { return nil }
    insert(image, for: cacheKey)
    return image
  }

  func invalidateIcon(at fileURL: URL) {
    let normalizedURL = fileURL.resolvingSymlinksInPath().standardizedFileURL
    cachedImages = cachedImages.filter { $0.key.fileURL != normalizedURL }
    accessOrder.removeAll { $0.fileURL == normalizedURL }
  }

  func removeAllCachedIcons() {
    cachedImages.removeAll(keepingCapacity: true)
    accessOrder.removeAll(keepingCapacity: true)
  }

  private func cacheKey(for fileURL: URL, maximumPixelSize: Int) -> CacheKey? {
    guard fileURL.isFileURL else { return nil }
    let normalizedURL = fileURL.resolvingSymlinksInPath().standardizedFileURL
    guard
      let values = try? normalizedURL.resourceValues(
        forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
      ),
      values.isRegularFile == true
    else {
      return nil
    }
    return CacheKey(
      fileURL: normalizedURL,
      fileSize: values.fileSize ?? 0,
      modificationDate: values.contentModificationDate,
      maximumPixelSize: maximumPixelSize
    )
  }

  private func cachedImage(for key: CacheKey) -> CGImage? {
    guard let image = cachedImages[key] else { return nil }
    recordAccess(to: key)
    return image
  }

  private func insert(_ image: CGImage, for key: CacheKey) {
    cachedImages[key] = image
    recordAccess(to: key)
    while accessOrder.count > maximumEntryCount {
      let discardedKey = accessOrder.removeFirst()
      cachedImages.removeValue(forKey: discardedKey)
    }
  }

  private func recordAccess(to key: CacheKey) {
    accessOrder.removeAll { $0 == key }
    accessOrder.append(key)
  }

  private nonisolated static func downsample(
    imageAt fileURL: URL,
    maximumPixelSize: Int
  ) -> CGImage? {
    let sourceOptions: [CFString: Any] = [
      kCGImageSourceShouldCache: false
    ]
    guard
      let source = CGImageSourceCreateWithURL(
        fileURL as CFURL,
        sourceOptions as CFDictionary
      )
    else {
      return nil
    }
    guard !Task.isCancelled else { return nil }

    let thumbnailOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
    ]
    return CGImageSourceCreateThumbnailAtIndex(
      source,
      0,
      thumbnailOptions as CFDictionary
    )
  }
}
