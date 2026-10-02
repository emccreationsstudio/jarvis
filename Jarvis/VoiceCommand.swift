import Foundation

/// Sesli komutlardaki bitiş sözleri ("bitti", "Jarvis kapan") ve soru tespiti.
enum VoiceCommand {
    enum End { case none, done, close }

    private static let tr = Locale(identifier: "tr_TR")

    private static func norm(_ w: Substring) -> String {
        String(w).lowercased(with: tr).trimmingCharacters(in: .punctuationCharacters.union(.symbols).union(.whitespaces))
    }

    /// Cümlenin sonundaki bitiş sözünü bulur ve ayıklar.
    static func parse(_ text: String) -> (body: String, end: End) {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        let n = words.map(norm)

        let close: [[String]] = [
            ["jarvis", "kapan"], ["kapan"], ["kapat"], ["kapanabilirsin"], ["jarvis", "kapat"],
            ["görüşürüz"], ["jarvis", "görüşürüz"], ["sağ", "ol", "jarvis"], ["kapanış"]
        ]
        let done: [[String]] = [
            ["bitti"], ["jarvis", "bitti"], ["tamam", "bitti"], ["bu", "kadar"], ["hepsi", "bu"],
            ["şimdilik", "bu", "kadar"], ["işle"], ["hadi", "işle"]
        ]

        func match(_ phrases: [[String]]) -> Int? {
            // En uzun eşleşmeyi tercih et
            for p in phrases.sorted(by: { $0.count > $1.count }) where p.count <= n.count {
                if Array(n.suffix(p.count)) == p { return p.count }
            }
            return nil
        }

        if let k = match(close) {
            return (body(words.dropLast(k)), .close)
        }
        if let k = match(done) {
            return (body(words.dropLast(k)), .done)
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), .none)
    }

    private static func body(_ words: ArraySlice<Substring>) -> String {
        var s = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        // Sondaki virgül vb. temizle; baştaki "Jarvis" hitabını at
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ",;:-–— "))
        if s.lowercased(with: tr).hasPrefix("jarvis") {
            s = String(s.dropFirst(6)).trimmingCharacters(in: CharacterSet(charactersIn: ",;:-–— "))
        }
        return s
    }

    /// Tamamlanmış bir komut ya da soru mu? (öyleyse kısa bekleyip cevap verilir)
    static func isComplete(_ text: String) -> Bool {
        if isQuestion(text) { return true }
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(norm)
        guard let last = words.last else { return false }
        // Türkçe emir kipi / istek sonları: "ekle", "hatırlat", "kur", "ara", "yaz", "sil", "oluştur", "ayarla"…
        let commandEndings = ["le", "la", "lat", "let", "kur", "ara", "yaz", "sil", "yap", "aç", "kapat",
                              "koy", "gönder", "bul", "planla", "oluştur", "ayarla", "hazırla", "çıkar", "bitir",
                              "lütfen", "rica", "et", "edin", "eyim", "ayım", "ırım", "irim", "urum", "ürüm"]
        if commandEndings.contains(where: { last.hasSuffix($0) }) { return true }
        let markers = ["hatırlat", "ekle", "kur", "oluştur", "ara", "sil", "planla", "not"]
        return words.contains(where: { w in markers.contains(where: { w.hasPrefix($0) }) }) && words.count >= 3
    }

    /// Hemen sesli cevap gerektiren bir soru/istek mi?
    static func isQuestion(_ text: String) -> Bool {
        if text.contains("?") { return true }
        let w = text.split(whereSeparator: { $0.isWhitespace }).map(norm)
        let particles: Set<String> = [
            "mı", "mi", "mu", "mü", "mısın", "misin", "musun", "müsün", "mıyım", "miyim", "muyum", "müyüm",
            "mıdır", "midir", "mudur", "müdür", "mıyız", "miyiz", "muyuz", "müyüz", "mısınız", "misiniz",
            "musunuz", "müsünüz", "mıydı", "miydi", "muydu", "müydü"
        ]
        let qWords: Set<String> = [
            "ne", "neden", "niye", "niçin", "nasıl", "nasılsın", "nerede", "nerde", "nereye", "nereden", "nereden",
            "kaç", "kaçta", "kaça", "kaçıncı", "kim", "kimi", "kime", "kimden", "kimle", "hangi", "hangisi",
            "neler", "nedir", "neresi", "ne zaman"
        ]
        // Bilgi isteyen emirler: cevabı sesli duymak istenir
        let askPrefixes: [String] = ["söyle", "anlat", "özetle", "hesapla", "açıkla", "öner"]
        let askExact: Set<String> = ["oku", "okur", "okusana", "okuyabilir", "okuyun", "bakar", "baksana", "sayar"]

        for x in w {
            if particles.contains(x) || qWords.contains(x) { return true }
            if x.hasPrefix("nere") || x.hasPrefix("nası") { return true }
            if askExact.contains(x) || askPrefixes.contains(where: { x.hasPrefix($0) }) { return true }
        }
        return false
    }
}
