import AppIntents
import UIKit

/// "Hey Siri, Jarvis" · Kısayollar · Arkaya Dokunma → uygulama açılır ve dinlemeye başlar
struct ListenIntent: AppIntent {
    static var title: LocalizedStringResource = "Jarvis'i Dinlet"
    static var description = IntentDescription("Jarvis'i açar ve hemen dinlemeye başlar.")
    static var openAppWhenRun: Bool = true

    /// 1.2.9: Siri tarafında hiçbir ağır iş yapılmaz (eskiden burada uygulamanın tamamı ayağa kalkıyordu;
    /// Siri bazen zaman aşımına düşüp "Bir sorun oluştu" diyordu). Sadece "dinle" isteği bırakılır,
    /// uygulama öne gelince dinlemeye başlar.
    @MainActor
    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "siriListenAt")
        NotificationCenter.default.post(name: .jarvisListenRequest, object: nil)
        return .result()
    }
}

extension Notification.Name {
    static let jarvisListenRequest = Notification.Name("jarvisListenRequest")
}

/// "Hey Siri, Jarvis'e söyle" → söylenecek metni sorar ve Jarvis'e iletir
struct TellIntent: AppIntent {
    static var title: LocalizedStringResource = "Jarvis'e Söyle"
    static var description = IntentDescription("Söylediğinizi Jarvis'e iletir.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Mesaj", requestValueDialog: "Ne söylemek istersin?")
    var message: String

    @MainActor
    func perform() async throws -> some IntentResult {
        Assistant.shared.send(message)
        return .result()
    }
}

struct JarvisShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ListenIntent(),
            phrases: [
                "\(.applicationName)",
                "Hey \(.applicationName)",
                "\(.applicationName) dinle",
                "\(.applicationName)'i aç",
                "\(.applicationName)'i çağır",
                "\(.applicationName) uyan",
                "Merhaba \(.applicationName)"
            ],
            shortTitle: "Jarvis'i Dinlet",
            systemImageName: "waveform.circle.fill"
        )
        AppShortcut(
            intent: TellIntent(),
            phrases: [
                "\(.applicationName)'e söyle",
                "\(.applicationName)'e sor"
            ],
            shortTitle: "Jarvis'e Söyle",
            systemImageName: "text.bubble.fill"
        )
    }
}
