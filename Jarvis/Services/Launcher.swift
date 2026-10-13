import Foundation
import UIKit

/// Telefonda uygulama / sayfa / kısayol açma ve bilgisayardaki Jarvis'e komut gönderme.
enum Launcher {
    /// Bilinen uygulamaların açılış adresleri (Türkçe ve İngilizce adlarıyla)
    private static let apps: [(names: [String], url: String)] = [
        (["whatsapp", "vatsap", "wp"], "whatsapp://"),
        (["instagram", "insta"], "instagram://"),
        (["youtube", "yutup"], "youtube://"),
        (["spotify"], "spotify://"),
        (["telegram"], "tg://"),
        (["twitter", "x"], "twitter://"),
        (["tiktok"], "snssdk1233://"),
        (["facebook"], "fb://"),
        (["linkedin"], "linkedin://"),
        (["gmail"], "googlegmail://"),
        (["mail", "e-posta", "eposta", "posta"], "message://"),
        (["mesajlar", "mesaj", "sms", "messages"], "sms://"),
        (["telefon", "rehber", "kişiler"], "mobilephone://"),
        (["harita", "haritalar", "apple haritalar", "maps"], "maps://"),
        (["google haritalar", "google maps"], "comgooglemaps://"),
        (["yandex", "yandex navigasyon", "yandex haritalar"], "yandexnavi://"),
        (["takvim", "calendar"], "calshow://"),
        (["fotoğraflar", "galeri", "photos"], "photos-redirect://"),
        (["müzik", "apple müzik", "music"], "music://"),
        (["podcast", "podcastler"], "podcasts://"),
        (["notlar", "notes"], "mobilenotes://"),
        (["hatırlatıcılar", "reminders"], "x-apple-reminderkit://"),
        (["saat", "alarm", "clock"], "clock-alarm://"),
        (["app store", "appstore"], "itms-apps://"),
        (["safari", "tarayıcı"], "x-web-search://"),
        (["chrome"], "googlechrome://"),
        (["netflix"], "nflx://"),
        (["zoom"], "zoomus://"),
        (["teams"], "msteams://"),
        (["slack"], "slack://"),
        (["uber"], "uber://"),
        (["bitaksi"], "bitaksi://"),
        (["getir"], "getir://"),
        (["trendyol"], "trendyol://"),
        (["yemeksepeti"], "yemeksepeti://"),
        (["kısayollar", "shortcuts"], "shortcuts://"),
        (["ayarlar", "settings"], UIApplication.openSettingsURLString)
    ]

    private static func key(_ s: String) -> String {
        s.lowercased(with: Locale(identifier: "tr_TR")).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Uygulamayı, web sayfasını ya da kısayolu açar. Açılamazsa false.
    @MainActor
    static func open(_ target: String) async -> Bool {
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        // Doğrudan adres verildiyse
        if t.contains("://") || t.hasPrefix("www.") {
            let raw = t.hasPrefix("www.") ? "https://" + t : t
            if let url = URL(string: raw) { return await UIApplication.shared.open(url) }
        }
        let k = key(t).replacingOccurrences(of: " uygulaması", with: "").replacingOccurrences(of: "'ı", with: "")
        let exact = apps.first { app in app.names.contains(k) }
        let loose = apps.first { app in app.names.contains { name in name.count > 3 && k.contains(name) } }
        if let hit = exact ?? loose, let url = URL(string: hit.url) {
            if await UIApplication.shared.open(url) { return true }
        }
        return false
    }

    /// Kısayollar uygulamasındaki bir kısayolu çalıştırır (kullanıcının kendi otomasyonları)
    @MainActor
    static func runShortcut(_ name: String, input: String? = nil) async -> Bool {
        var comps = URLComponents(string: "shortcuts://run-shortcut")
        comps?.queryItems = [URLQueryItem(name: "name", value: name)]
            + (input.map { [URLQueryItem(name: "input", value: "text"), URLQueryItem(name: "text", value: $0)] } ?? [])
        guard let url = comps?.url else { return false }
        return await UIApplication.shared.open(url)
    }

    /// Web'de arar ya da sayfayı açar
    @MainActor
    static func search(_ query: String) async -> Bool {
        var comps = URLComponents(string: "https://www.google.com/search")
        comps?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = comps?.url else { return false }
        return await UIApplication.shared.open(url)
    }

    // MARK: Bilgisayardaki Jarvis'e komut

    struct PCReply: Decodable { let id: String?; let status: String?; let reply: String? }

    /// Komutu sunucudaki kuyruğa bırakır; bilgisayardaki Jarvis birkaç saniye içinde alıp yapar.
    /// Cevap 45 sn içinde gelirse döndürür.
    static func sendToPC(_ text: String) async -> String {
        let s = await MainActor.run { (AppSettings.shared.serverURL, AppSettings.shared.token) }
        let root = s.0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: root + "/pc") else { return "Sunucu adresi geçersiz." }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(s.1)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
        guard let result = try? await URLSession.shared.data(for: req),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let sent = try? JSONDecoder().decode(PCReply.self, from: result.0), let id = sent.id else {
            return "Komutu bilgisayara iletemedim; sunucuda bilgisayar kuyruğu kurulu olmayabilir."
        }
        guard let resultURL = URL(string: root + "/pc/result?id=" + id) else { return "" }
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            var r = URLRequest(url: resultURL, timeoutInterval: 10)
            r.setValue("Bearer \(s.1)", forHTTPHeaderField: "Authorization")
            if let res = try? await URLSession.shared.data(for: r),
               (res.1 as? HTTPURLResponse)?.statusCode == 200,
               let out = try? JSONDecoder().decode(PCReply.self, from: res.0),
               out.status == "done" {
                return "Bilgisayar: " + (out.reply ?? "Tamam.")
            }
        }
        return "Komutu bilgisayara ilettim; bilgisayar açıksa Jarvis birazdan yapacak."
    }
}
