import AppKit
import AVFoundation
import ImageIO
import Quartz
import UniformTypeIdentifiers
import Vision

/// Quick conversions for files on the Shelf. Results are saved next to the original with
/// a suffix, never replacing it.
enum FileConverter {
    enum Kind: CaseIterable {
        case jpeg, compressPDF, shrinkVideo
        var title: String { switch self { case .jpeg: "Convert to JPG"; case .compressPDF: "Compress PDF"; case .shrinkVideo: "Shrink video for sharing" } }
        var symbol: String { switch self { case .jpeg: "photo"; case .compressPDF: "doc.zipper"; case .shrinkVideo: "film" } }
    }

    /// The conversions that make sense for a file.
    static func options(for url: URL) -> [Kind] {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return [] }
        if type.conforms(to: .image), type != .jpeg { return [.jpeg] }
        if type.conforms(to: .pdf) { return [.compressPDF] }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return [.shrinkVideo] }
        return []
    }

    static func convert(_ url: URL, to kind: Kind) async throws -> URL {
        switch kind {
        case .jpeg: return try jpeg(url)
        case .compressPDF: return try compressPDF(url)
        case .shrinkVideo: return try await shrinkVideo(url)
        }
    }

    // MARK: Text from images

    static func isImage(_ url: URL) -> Bool { UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .image) == true }
    /// Reads the text in an image (a slide screenshot, a photo of a whiteboard) on this Mac.
    static func recognizeText(in url: URL) async throws -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw failure("That image couldn't be read.") }
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error { continuation.resume(throwing: error); return }
                let lines = (request.results as? [VNRecognizedTextObservation] ?? []).compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch { continuation.resume(throwing: error) }
        }
    }

    // MARK: Photos to PDF

    /// One page per image, in order, sized to each photo (scaled to about 2400 px so phone
    /// photos don't make a huge file), saved as "Photos.pdf" next to the first.
    static func imagesToPDF(_ urls: [URL]) throws -> URL {
        let images = urls.filter(isImage)
        guard let first = images.first else { throw failure("Put photos or screenshots on the Shelf first.") }
        let document = PDFDocument()
        for url in images {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2400] as CFDictionary) else {
                throw failure("\(url.lastPathComponent) couldn't be read.")
            }
            // Re-encode as JPEG so pages stay small.
            let rep = NSBitmapImageRep(cgImage: image)
            guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]), let page = NSImage(data: jpeg).flatMap(PDFPage.init(image:)) else { throw failure("\(url.lastPathComponent) couldn't be added.") }
            document.insert(page, at: document.pageCount)
        }
        let output = destination(for: first.deletingLastPathComponent().appendingPathComponent("Photos.pdf"), suffix: "", extension: "pdf")
        guard document.write(to: output) else { throw failure("Couldn't save the PDF.") }
        return output
    }

    // MARK: Merging

    static func isPDF(_ url: URL) -> Bool { UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .pdf) == true }
    /// Joins PDFs in the order given into "Merged PDF.pdf" next to the first one.
    static func merge(_ urls: [URL]) throws -> URL {
        let pdfs = urls.filter(isPDF)
        guard pdfs.count >= 2, let first = pdfs.first else { throw failure("Put two or more PDFs on the Shelf to merge them.") }
        let merged = PDFDocument()
        for url in pdfs {
            guard let document = PDFDocument(url: url) else { throw failure("\(url.lastPathComponent) couldn't be opened.") }
            if document.isLocked { throw failure("\(url.lastPathComponent) is password-protected.") }
            for index in 0..<document.pageCount { if let page = document.page(at: index) { merged.insert(page, at: merged.pageCount) } }
        }
        let output = destination(for: first.deletingLastPathComponent().appendingPathComponent("Merged PDF.pdf"), suffix: "", extension: "pdf")
        guard merged.write(to: output) else { throw failure("Couldn't save the merged PDF.") }
        return output
    }

    // MARK: Images

    private static func jpeg(_ url: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else { throw failure("That image couldn't be read.") }
        let output = destination(for: url, suffix: "", extension: "jpg")
        guard let target = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw failure("Couldn't write the JPG.") }
        // Keeps orientation and metadata; quality 0.88 is visually lossless for photos.
        CGImageDestinationAddImageFromSource(target, source, 0, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(target) else { throw failure("Couldn't write the JPG.") }
        return output
    }

    // MARK: PDFs

    private static func compressPDF(_ url: URL) throws -> URL {
        guard let document = PDFDocument(url: url) else { throw failure("That PDF couldn't be opened.") }
        let output = destination(for: url, suffix: " (smaller)", extension: "pdf")
        // The same "Reduce File Size" filter Preview uses: images shrink, text stays selectable.
        let filter = QuartzFilter(url: URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter"))
        let options: [PDFDocumentWriteOption: Any] = filter.map { [PDFDocumentWriteOption(rawValue: "QuartzFilter"): $0] } ?? [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
        guard document.write(to: output, withOptions: options) else { throw failure("Couldn't save the smaller PDF.") }
        // Keep the original when "compressing" didn't help (text-only PDFs).
        let before = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let after = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if after >= before { try? FileManager.default.removeItem(at: output); throw failure("That PDF is already as small as it gets.") }
        return output
    }

    // MARK: Video

    private static func shrinkVideo(_ url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let preset = AVAssetExportPresetHEVC1920x1080
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) ?? AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else { throw failure("That video can't be converted.") }
        let output = destination(for: url, suffix: " (small)", extension: "mp4")
        try await session.export(to: output, as: .mp4)
        return output
    }

    // MARK: Helpers

    /// "Photo.jpg", or "Photo 2.jpg" when that exists.
    private static func destination(for url: URL, suffix: String, extension ext: String) -> URL {
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent + suffix
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(number)").appendingPathExtension(ext); number += 1
        }
        return candidate
    }
    private static func failure(_ message: String) -> NSError { NSError(domain: "Attending", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
