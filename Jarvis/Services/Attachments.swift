import AVFoundation
import Contacts
import CoreLocation
import CoreTransferable
import PDFKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 1.2.7: WhatsApp'taki gibi ekler — fotoğraf, video, kamera, belge, konum, kişi.
/// Resimler sunucuya küçültülüp gönderilir (yapay zekâ görür); belge/konum/kişi metne çevrilip mesaja eklenir.
struct Attachment: Identifiable, Equatable {
    enum Kind: String { case image, video, document, location, contact }
    let id = UUID()
    let kind: Kind
    let label: String
    /// data:image/jpeg;base64,... (en fazla 3 tane gönderilir)
    var images: [String] = []
    /// Yapay zekânın okuyacağı metin (belge içeriği, adres, kişi bilgisi)
    var text: String?

    var icon: String {
        switch kind {
        case .image: return "photo"
        case .video: return "video"
        case .document: return "doc.text"
        case .location: return "location.fill"
        case .contact: return "person.crop.circle"
        }
    }
}

/// Galeriden video seçebilmek için
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + (received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension))
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest)
        }
    }
}

enum AttachmentMaker {
    static let maxDocChars = 60_000

    /// Belge seçicide kabul edilen türler
    static var documentTypes: [UTType] {
        var t: [UTType] = [.pdf, .plainText, .utf8PlainText, .rtf, .commaSeparatedText, .json, .image, .html, .xml]
        if let md = UTType(filenameExtension: "md") { t.append(md) }
        if let docx = UTType(filenameExtension: "docx") { t.append(docx) }
        return t
    }

    // MARK: Resim

    static func dataURL(_ image: UIImage, maxSide: CGFloat = 1568, quality: CGFloat = 0.75) -> String? {
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height, 1))
        let target = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let data = resized.jpegData(compressionQuality: quality) else { return nil }
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }

    static func image(_ image: UIImage, label: String = "Fotoğraf") -> Attachment? {
        guard let url = dataURL(image) else { return nil }
        return Attachment(kind: .image, label: label, images: [url])
    }

    // MARK: Video — 3 kare alınır (başı, ortası, sonu)

    static func video(_ url: URL) async -> Attachment? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1280, height: 1280)
        let seconds = (try? await asset.load(.duration).seconds) ?? 0
        let times = seconds > 1 ? [0.1, seconds / 2, max(0, seconds - 0.3)] : [0]
        var urls: [String] = []
        for t in times {
            if let cg = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image,
               let d = dataURL(UIImage(cgImage: cg), maxSide: 1024) {
                urls.append(d)
            }
        }
        guard !urls.isEmpty else { return nil }
        let len = seconds > 0 ? " (\(Int(seconds.rounded())) sn)" : ""
        return Attachment(kind: .video, label: "Video" + len, images: urls,
                          text: "Kullanıcı\(len) bir video gönderdi; videonun başından, ortasından ve sonundan 3 kare ekte.")
    }

    // MARK: Belge

    static func document(_ url: URL) async -> Attachment? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)

        if let type, type.conforms(to: .image),
           let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
            return image(img, label: name)
        }
        if ext == "pdf", let pdf = PDFDocument(url: url) {
            var text = ""
            for i in 0..<pdf.pageCount {
                if let s = pdf.page(at: i)?.string { text += "\n--- Sayfa \(i + 1) ---\n" + s }
                if text.count > maxDocChars { break }
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count > 200 {
                return Attachment(kind: .document, label: name, text: header(name, pdf.pageCount) + String(trimmed.prefix(maxDocChars)))
            }
            // Taranmış PDF (yazı yok) → ilk 3 sayfa resim olarak
            var urls: [String] = []
            for i in 0..<min(3, pdf.pageCount) {
                guard let page = pdf.page(at: i) else { continue }
                let thumb = page.thumbnail(of: CGSize(width: 1400, height: 1400), for: .mediaBox)
                if let d = dataURL(thumb) { urls.append(d) }
            }
            return Attachment(kind: .document, label: name, images: urls,
                              text: "Kullanıcı \(name) adlı taranmış bir PDF gönderdi (\(pdf.pageCount) sayfa); ilk sayfalar resim olarak ekte.")
        }
        if ext == "docx", let text = DocxText.read(url) {
            return Attachment(kind: .document, label: name, text: header(name, nil) + String(text.prefix(maxDocChars)))
        }
        if ext == "rtf", let attr = try? NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            return Attachment(kind: .document, label: name, text: header(name, nil) + String(attr.string.prefix(maxDocChars)))
        }
        if let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1254) {
            return Attachment(kind: .document, label: name, text: header(name, nil) + String(text.prefix(maxDocChars)))
        }
        return nil
    }

    private static func header(_ name: String, _ pages: Int?) -> String {
        "EKLİ BELGE: \(name)" + (pages.map { " (\($0) sayfa)" } ?? "") + "\n"
    }

    // MARK: Konum

    @MainActor
    static func location() async -> Attachment? {
        await RouteService.shared.requestPermission()
        guard let loc = await RouteService.shared.preciseLocation() else { return nil }
        var address = ""
        if let p = try? await CLGeocoder().reverseGeocodeLocation(loc, preferredLocale: Locale(identifier: "tr_TR")).first {
            address = [p.name, p.thoroughfare, p.subLocality, p.locality, p.administrativeArea]
                .compactMap { $0 }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                .joined(separator: ", ")
        }
        let lat = String(format: "%.6f", loc.coordinate.latitude)
        let lon = String(format: "%.6f", loc.coordinate.longitude)
        let label = address.isEmpty ? "Konumum" : address
        return Attachment(kind: .location, label: label,
                          text: "KULLANICININ PAYLAŞTIĞI KONUM: \(address.isEmpty ? "" : address + " · ")\(lat), \(lon) (doğruluk ~\(Int(loc.horizontalAccuracy)) m). Harita: https://maps.apple.com/?ll=\(lat),\(lon)")
    }

    // MARK: Kişi

    static func contact(_ c: CNContact) -> Attachment {
        let name = CNContactFormatter.string(from: c, style: .fullName) ?? "Kişi"
        var lines = ["PAYLAŞILAN KİŞİ: \(name)"]
        for p in c.phoneNumbers { lines.append("Telefon: \(p.value.stringValue)") }
        for e in c.emailAddresses { lines.append("E-posta: \(e.value as String)") }
        if !c.organizationName.isEmpty { lines.append("Şirket: \(c.organizationName)") }
        return Attachment(kind: .contact, label: name, text: lines.joined(separator: "\n"))
    }
}

/// .docx içindeki yazıyı okur (ZIP içindeki word/document.xml). Yalnızca "stored" ve "deflate" sıkıştırma.
enum DocxText {
    static func read(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let xml = ZipLite.extract("word/document.xml", from: data),
              let s = String(data: xml, encoding: .utf8) else { return nil }
        var out = s.replacingOccurrences(of: "</w:p>", with: "\n")
        out = out.replacingOccurrences(of: "<w:tab/>", with: "\t")
        out = out.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (k, v) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'"] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

enum ZipLite {
    static func extract(_ name: String, from data: Data) -> Data? {
        let bytes = [UInt8](data)
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        // Merkez dizinin sonu
        guard bytes.count > 22 else { return nil }
        var eocd = -1
        var i = bytes.count - 22
        while i >= max(0, bytes.count - 66_000) {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4b, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return nil }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
        for _ in 0..<count {
            guard p + 46 <= bytes.count, u32(p) == 0x02014b50 else { return nil }
            let method = u16(p + 10)
            let csize = u32(p + 20)
            let usize = u32(p + 24)
            let nlen = u16(p + 28), elen = u16(p + 30), clen = u16(p + 32)
            let local = u32(p + 42)
            guard p + 46 + nlen <= bytes.count else { return nil }
            let fname = String(bytes: bytes[(p + 46)..<(p + 46 + nlen)], encoding: .utf8) ?? ""
            p += 46 + nlen + elen + clen
            guard fname == name, local + 30 <= bytes.count else { continue }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + csize <= bytes.count else { return nil }
            let comp = Data(bytes[start..<(start + csize)])
            if method == 0 { return comp }
            if method == 8 { return (try? (comp as NSData).decompressed(using: .zlib)).map { $0 as Data } }
            _ = usize
            return nil
        }
        return nil
    }
}
