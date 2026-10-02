import AppIntents
import UIKit

/// "Hey Siri, Jarvis" · Kısayollar · Arkaya Dokunma → uygulama açılır ve dinlemeye başlar
struct ListenIntent: AppIntent {
    static var title: LocalizedStringResource = "Jarvis'i Dinlet"
    static var description = IntentDescription("Jarvis'i açar ve hemen dinlemeye başlar.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        Assistant.shared.listenRequested = true
        // Uygulama zaten açıksa da tetiklensin
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Assistant.shared.listenRequested, UIApplication.shared.applicationState == .active {
                Assistant.shared.listenRequested = false
                Assistant.shared.startListening()
            }
        }
        return .result()
    }
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
                "\(.applicationName)'i aç"
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
