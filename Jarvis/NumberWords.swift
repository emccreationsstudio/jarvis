import Foundation

/// Söylenen sayıları rakama çevirir: "yarın saat dörtte iki domates" → "yarın saat 4'te 2 domates".
/// Bilgisayar uygulamasındaki numbers.js ile aynı kurallar (orada testleri var).
/// "bir şey", "ona söyle", "otobüse bin", "yemek yedi" gibi sayı olmayan kullanımlara dokunmaz.
enum NumberWords {
    private static let tr = Locale(identifier: "tr_TR")

    private static let roots: [String: Int] = [
        "sıfır": 0, "bir": 1, "iki": 2, "üç": 3, "dört": 4, "dörd": 4, "beş": 5, "altı": 6, "yedi": 7, "sekiz": 8, "dokuz": 9,
        "on": 10, "yirmi": 20, "otuz": 30, "kırk": 40, "elli": 50, "altmış": 60, "yetmiş": 70, "seksen": 80, "doksan": 90,
        "yüz": 100, "bin": 1000, "milyon": 1_000_000
    ]
    private static let rootNames: [String] = roots.keys.sorted { $0.count > $1.count }

    /// Başka anlamı da olan sözcükler
    private static let ambiguous: Set<String> = ["bir", "on", "altı", "yedi", "yüz", "bin"]
    /// Bunlardan önce gelirse sayı olduğu kesin
    private static let timeBefore: Set<String> = ["saat", "saati", "sabah", "akşam", "gece", "öğlen", "öğle", "sonra", "yarın",
                                                  "bugün", "ayın", "yüzde", "toplam", "tam", "en", "fazla", "az"]
    /// Bunlar ardından gelirse sayı olduğu kesin
    private static let unitAfter: Set<String> = [
        "tane", "adet", "kilo", "kg", "gram", "gr", "litre", "lt", "paket", "kutu", "şişe", "koli", "düzine", "dilim", "porsiyon",
        "lira", "tl", "dolar", "euro", "avro", "kuruş", "kişi", "kişilik", "saat", "saatte", "dakika", "dakikada", "saniye",
        "gün", "günde", "hafta", "ay", "yıl", "sene", "kez", "defa", "kere", "metre", "km", "kilometre", "numara", "numaralı",
        "buçuk", "çeyrek", "milyon", "bin", "yüz", "mg", "ml", "doz", "hap", "tablet", "kapsül", "damla", "ölçek"
    ]

    private static let suffixRE = try! NSRegularExpression(
        pattern: "^(y?[aeıiuü]|[dt][ae]n?|n?[ıiuü]n|s?[ıiuü]n?[dt]?[ae]|s?[ıiuü]n[ıiuü]|s?[ıiuü]|[ıiuü]?nc[ıiuü])$")
    private static let ordinalRE = try! NSRegularExpression(pattern: "^[ıiuü]?nc[ıiuü]$")
    private static let genitiveRE = try! NSRegularExpression(pattern: "(ın|in|un|ün)$")

    private struct Info { let value: Int; let suffix: String; let root: String }
    private struct Token { let raw: String; let word: String; let punct: String; let info: Info? }
    private enum Group { case word(Token), num([Token]) }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    private static func lower(_ s: String) -> String { s.lowercased(with: tr) }

    /// "beşte" → (5, "te")
    private static func analyze(_ word: String) -> Info? {
        let w = lower(word)
        if let v = roots[w] { return Info(value: v, suffix: "", root: w == "dörd" ? "dört" : w) }
        if w == "yüzde" { return nil }
        for r in rootNames where w.hasPrefix(r) && w.count > r.count {
            let rest = String(w.dropFirst(r.count))
            if matches(suffixRE, rest), let v = roots[r] {
                return Info(value: v, suffix: rest, root: r == "dörd" ? "dört" : r)
            }
        }
        return nil
    }

    /// Belirsiz kök eksiz söylendiğinde yine de sayı mı?
    private static func bareIsNumber(_ info: Info, prevWord: String?, atEnd: Bool) -> Bool {
        if !info.suffix.isEmpty { return false }          // "ona", "biri", "altında" → bağlam gerekir
        switch info.root {
        case "on", "yüz": return true
        case "altı": return !(prevWord.map { matches(genitiveRE, $0) } ?? false)   // "masanın altı" değil
        case "yedi": return !atEnd                                                  // "yemek yedi" değil
        default: return false                                                       // "bir", "bin"
        }
    }

    /// "yirmi beş" evet, "iki üç" hayır
    private static func canFollow(_ prev: Int, _ next: Int) -> Bool {
        if next < 10 { return prev >= 10 }
        if next < 100 { return prev >= 100 }
        if next == 100 { return (prev >= 2 && prev < 10) || prev >= 1000 }
        return prev < next
    }

    private static func value(of group: [Token]) -> Int {
        var total = 0, current = 0
        for t in group {
            guard let v = t.info?.value else { continue }
            if v == 100 { current = (current == 0 ? 1 : current) * 100 }
            else if v >= 1000 { total += (current == 0 ? 1 : current) * v; current = 0 }
            else { current += v }
        }
        return total + current
    }

    private static let punctuation: Set<Character> = [".", ",", "!", "?", ";", ":", "…"]

    static func normalize(_ input: String) -> String {
        let text = input.precomposedStringWithCanonicalMapping
        let parts = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !parts.isEmpty else { return input }

        let tokens: [Token] = parts.map { part in
            var word = part
            var punct = ""
            while let last = word.last, punctuation.contains(last) {
                punct = String(last) + punct
                word.removeLast()
            }
            return Token(raw: part, word: word, punct: punct, info: word.isEmpty ? nil : analyze(word))
        }

        // Sayı grupları
        var groups: [Group] = []
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            guard t.info != nil else { groups.append(.word(t)); i += 1; continue }
            var grp = [t]
            var j = i + 1
            while j < tokens.count, let next = tokens[j].info, let last = grp.last, let lastInfo = last.info {
                if !lastInfo.suffix.isEmpty || !last.punct.isEmpty { break }
                if !canFollow(lastInfo.value, next.value) { break }
                grp.append(tokens[j])
                j += 1
            }
            groups.append(.num(grp))
            i = j
        }

        var words: [String] = []
        for (g, group) in groups.enumerated() {
            switch group {
            case .word(let t):
                words.append(t.raw)
            case .num(let grp):
                guard let first = grp.first, let last = grp.last, let firstInfo = first.info, let lastInfo = last.info else { continue }
                var prevWord: String? = nil
                var prevIsNum = false
                if g > 0 {
                    switch groups[g - 1] {
                    case .word(let p): prevWord = lower(p.word)
                    case .num: prevIsNum = true
                    }
                }
                var nextWord: String? = nil
                var nextIsNum = false
                if g + 1 < groups.count {
                    switch groups[g + 1] {
                    case .word(let n): nextWord = lower(n.word)
                    case .num: nextIsNum = true
                    }
                }

                if grp.count == 1 && ambiguous.contains(firstInfo.root) {
                    let sure = (prevWord.map { timeBefore.contains($0) } ?? false)
                        || (nextWord.map { unitAfter.contains($0) } ?? false)
                        || nextIsNum || prevIsNum
                    let atEnd = g + 1 >= groups.count || !first.punct.isEmpty
                    if !sure && !bareIsNumber(firstInfo, prevWord: prevWord, atEnd: atEnd) {
                        words.append(first.raw)
                        continue
                    }
                }

                let n = value(of: grp)
                let suffix = lastInfo.suffix
                let out: String
                if !suffix.isEmpty && matches(ordinalRE, suffix) { out = "\(n)." }
                else if !suffix.isEmpty { out = "\(n)'\(suffix)" }
                else { out = "\(n)" }
                words.append(out + last.punct)
            }
        }

        var s = words.joined(separator: " ")
        s = replace(s, "\\byüzde (\\d+)", "%$1")
        s = replace(s, "(saat) (\\d{1,2}) (\\d{2})(?=$|[\\s'.,!?])", "$1 $2.$3")
        s = replace(s, "(saat) (\\d{1,2}) buçuk(?:ta|da)(?=$|[\\s.,!?])", "$1 $2.30'da")
        s = replace(s, "(saat) (\\d{1,2}) buçuk(?=$|[\\s.,!?])", "$1 $2.30")
        return s
    }

    private static func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}
