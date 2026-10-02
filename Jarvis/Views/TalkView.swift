import SwiftUI

struct RootView: View {
    @EnvironmentObject var assistant: Assistant
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @AppStorage("didOnboard") private var didOnboard = false

    var body: some View {
        TabView(selection: $tab) {
            TalkView()
                .tabItem { Label("Jarvis", systemImage: "waveform.circle.fill") }
                .tag(0)
            ListsView()
                .tabItem { Label("Listeler", systemImage: "checklist") }
                .tag(1)
            MemoryView()
                .tabItem { Label("Hafıza", systemImage: "brain.head.profile") }
                .tag(2)
            SettingsView()
                .tabItem { Label("Ayarlar", systemImage: "gearshape.fill") }
                .tag(3)
        }
        .onChange(of: assistant.listenRequested) { _, requested in
            guard requested else { return }
            assistant.listenRequested = false
            tab = 0
            if assistant.phase == .idle {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { assistant.startListening() }
            }
        }
        .sheet(isPresented: Binding(get: { !didOnboard }, set: { if !$0 { didOnboard = true } })) {
            OnboardingView { didOnboard = true }
        }
    }
}

struct TalkView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var assistant: Assistant
    @State private var input = ""
    @FocusState private var typing: Bool

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                messages
                if let route = assistant.lastRoute {
                    Button {
                        RouteService.shared.openInMaps(route)
                    } label: {
                        Label("Haritalar'da aç", systemImage: "car.fill")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(Theme.accent.opacity(0.2), in: Capsule())
                    }
                    .padding(.bottom, 8)
                }
                if let err = assistant.errorText {
                    Text(err).font(.footnote).foregroundStyle(.orange).padding(.horizontal).padding(.bottom, 6)
                        .multilineTextAlignment(.center)
                }
                OrbButton()
                    .padding(.vertical, 12)
                inputBar
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(settings.assistantName.uppercased())
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .tracking(6)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !store.messages.isEmpty {
                Menu {
                    Button("Sohbeti temizle", role: .destructive) { store.messages.removeAll() }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private var statusText: String {
        switch assistant.phase {
        case .idle: return settings.isConfigured ? "Hazır" : "Ayarlar'dan sunucuyu bağlayın"
        case .listening: return "Dinliyorum…"
        case .thinking: return "Düşünüyorum…"
        case .speaking: return "Konuşuyor"
        }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if store.messages.isEmpty {
                        EmptyHint()
                    }
                    ForEach(store.messages.suffix(60)) { m in
                        Bubble(message: m).id(m.id)
                    }
                    if assistant.phase == .listening, !assistant.speech.partialText.isEmpty {
                        Bubble(message: ChatMessage(role: .user, text: assistant.speech.partialText))
                            .opacity(0.6)
                            .id("partial")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.messages.count) { _, _ in
                if let last = store.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            .onAppear {
                if let last = store.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Yazarak sor…", text: $input, axis: .vertical)
                .lineLimit(1...4)
                .focused($typing)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
                .submitLabel(.send)
                .onSubmit(sendTyped)
            if !input.trimmingCharacters(in: .whitespaces).isEmpty {
                Button(action: sendTyped) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                }
                .disabled(assistant.phase == .thinking)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private func sendTyped() {
        let text = input
        input = ""
        typing = false
        assistant.send(text)
    }
}

private struct EmptyHint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Örnekler").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach([
                "Alınacaklara domates ve damacana su ekle",
                "Yarın saat 10'da çok önemli toplantım var, alarm gibi hatırlat",
                "Ahmet'i aramam lazım, klip bütçesini konuşacağız",
                "Maslak'tan Zekeriyaköy'e nasıl gideyim?",
                "Bugün planım ne?",
                "Cuma stüdyoda vokal kaydım var, bana hazırlık programı yap"
            ], id: \.self) { s in
                Text("“\(s)”").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
        .padding(.top, 20)
    }
}

private struct Bubble: View {
    let message: ChatMessage
    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            Text(message.text)
                .font(.body)
                .textSelection(.enabled)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(
                    message.role == .user ? Theme.accent.opacity(0.85) : Theme.card,
                    in: RoundedRectangle(cornerRadius: 18)
                )
                .foregroundStyle(.white)
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }
}

struct OrbButton: View {
    @EnvironmentObject var assistant: Assistant
    @State private var pulse = false

    var body: some View {
        Button(action: assistant.toggleListening) {
            ZStack {
                Circle()
                    .fill(Theme.glow.opacity(glowOpacity))
                    .frame(width: 150, height: 150)
                    .blur(radius: 30)
                    .scaleEffect(scale)
                Image("Orb")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)
                    .clipShape(Circle())
                    .scaleEffect(assistant.phase == .listening ? 1.0 + CGFloat(assistant.speech.level) * 0.15 : 1.0)
                    .animation(.easeOut(duration: 0.12), value: assistant.speech.level)
                if assistant.phase == .thinking {
                    ProgressView().controlSize(.large).tint(.white)
                }
            }
            .frame(width: 160, height: 160)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(assistant.phase == .listening ? "Dinlemeyi bitir" : "Konuşmaya başla")
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private var glowOpacity: Double {
        switch assistant.phase {
        case .listening: return 0.8
        case .speaking: return 0.6
        case .thinking: return 0.45
        case .idle: return 0.3
        }
    }

    private var scale: CGFloat {
        assistant.phase == .idle ? (pulse ? 1.05 : 0.95) : (pulse ? 1.2 : 1.0)
    }
}
