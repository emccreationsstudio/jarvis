import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate {
    let notificationDelegate = NotificationDelegate()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = notificationDelegate
        Task { @MainActor in Reminders.shared.registerCategories() }
        return true
    }
}

@main
struct JarvisApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = Store.shared
    @StateObject private var settings = AppSettings.shared
    @StateObject private var assistant = Assistant.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(assistant)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

enum Theme {
    static let accent = Color(red: 0.25, green: 0.65, blue: 1.0)
    static let glow = Color(red: 0.35, green: 0.78, blue: 1.0)
    /// Diğer sekmeler için sakin arka plan
    static var background: some View { JarvisBackground(focus: .init(x: 0.5, y: 0.0), intensity: 0.6) }
    static let card = Color(red: 0.06, green: 0.12, blue: 0.20).opacity(0.55)
    static let cardStroke = Color(red: 0.35, green: 0.78, blue: 1.0).opacity(0.18)

    static func color(for p: Priority) -> Color {
        switch p {
        case .critical: return .red
        case .high: return .orange
        case .normal: return accent
        case .low: return .gray
        }
    }
}
