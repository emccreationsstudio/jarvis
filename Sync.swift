import Foundation

/// İsteğe bağlı cihazlar arası eşitleme (telefon ↔ bilgisayar).
/// Sunucuda tüm veri tek kayıt olarak durur; en son değiştiren kazanır.
@MainActor
final class SyncService {
    static let shared = SyncService()

    private var pushTask: Task<Void, Never>?
    private var pulling = false
    /// Ayarlar'da gösterilen son durum
    private(set) var lastStatus: String = "Henüz eşitlenmedi"

    private struct Envelope: Codable {
        let updatedAt: String?
        let data: Store.Snapshot?
    }

    private var settings: AppSettings { AppSettings.shared }

    private func endpoint() -> URL? {
        let base = settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: base + "/sync")
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]   // 2026-10-03T10:00:00.123Z
        return f
    }()

    /// Sunucudaki veri daha yeniyse al
    @discardableResult
    func pull() async -> String {
        guard settings.syncEnabled, settings.isConfigured, let url = endpoint(), !pulling else { return lastStatus }
        pulling = true
        defer { pulling = false }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 501 { lastStatus = "Sunucuda eşitleme kurulmamış (JARVIS_KV)."; return lastStatus }
            guard status == 200 else { lastStatus = "Eşitleme hatası (\(status))"; return lastStatus }
            let env = try Store.makeDecoder().decode(Envelope.self, from: data)
            guard let stamp = env.updatedAt, let remoteDate = Self.parse(stamp), let snap = env.data else {
                // Sunucu boş → bizdekini gönder
                schedulePush(immediately: true)
                lastStatus = "Sunucuya ilk kez gönderiliyor"
                return lastStatus
            }
            let store = Store.shared
            if remoteDate > store.updatedAt.addingTimeInterval(0.5) {
                store.applyRemote(snap, updatedAt: remoteDate)
                lastStatus = "Güncellendi · " + Date().formatted(date: .omitted, time: .shortened)
            } else if store.updatedAt > remoteDate.addingTimeInterval(0.5) {
                schedulePush(immediately: true)
                lastStatus = "Bu cihaz daha yeni, gönderiliyor"
            } else {
                lastStatus = "Eşit · " + Date().formatted(date: .omitted, time: .shortened)
            }
        } catch {
            lastStatus = "Sunucuya ulaşılamadı"
        }
        return lastStatus
    }

    /// Yerel değişiklikten 2 sn sonra gönder (art arda değişiklikleri birleştirir)
    func schedulePush(immediately: Bool = false) {
        guard settings.syncEnabled, settings.isConfigured else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            guard !Task.isCancelled else { return }
            await self?.push()
        }
    }

    private func push() async {
        guard let url = endpoint() else { return }
        let store = Store.shared
        let stamp = Self.iso.string(from: store.updatedAt == .distantPast ? Date() : store.updatedAt)
        guard let body = try? Store.makeEncoder().encode(Envelope(updatedAt: stamp, data: store.snapshot)) else { return }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        req.httpBody = body
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 409, let env = try? Store.makeDecoder().decode(Envelope.self, from: data),
               let s = env.updatedAt, let d = Self.parse(s), let snap = env.data {
                // Bilgisayarda daha yeni değişiklik var → onu al
                store.applyRemote(snap, updatedAt: d)
                lastStatus = "Diğer cihazdaki daha yeni veri alındı"
            } else if status == 200 {
                lastStatus = "Gönderildi · " + Date().formatted(date: .omitted, time: .shortened)
            } else {
                lastStatus = "Gönderilemedi (\(status))"
            }
        } catch {
            lastStatus = "Sunucuya ulaşılamadı"
        }
    }

    private static func parse(_ s: String) -> Date? {
        iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
