import SwiftUI

struct RootView: View {
    @EnvironmentObject var assistant: Assistant
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @AppStorage("didOnboard") private var didOnboard = false

    private func consumeListenRequest() {
        guard assistant.listenRequested else { return }
        tab = 0
        // Uygulama ön plana tam geçmeden mikrofon açılmaz → kısa bekle
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard assistant.listenRequested, UIApplication.shared.applicationState == .active else { return }
            assistant.listenRequested = false
            assistant.startListening()
        }
    }

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
        // "Hey Siri, Jarvis": istek uygulama tamamen açılmadan gelebilir → her fırsatta kontrol et
        .onAppear { consumeListenRequest() }
        .onChange(of: assistant.listenRequested) { _, _ in consumeListenRequest() }
        .onChange(of: scenePhase) { _, p in if p == .active { consumeListenRequest() } }
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

    // Arka plan görselindeki ölçüler (piksel, 853×1844 üzerinden)
    private let imgSize = CGSize(width: 853, height: 1844)
    private let reactorCenter = CGPoint(x: 426, y: 312)
    private let reactorRing: CGFloat = 290      // mavi halka çapı
    private let panelTop: CGFloat = 548          // ortadaki panelin üstü
    private let panelSide: CGFloat = 132         // panelin yan kenarları

    var body: some View {
        ZStack {
            Image("Backdrop")
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .ignoresSafeArea()
                .allowsHitTesting(false)

            GeometryReader { geo in
                let ins = geo.safeAreaInsets
                let W = geo.size.width + ins.leading + ins.trailing
                let H = geo.size.height + ins.top + ins.bottom
                let k = max(W / imgSize.width, H / imgSize.height)
                let x0 = (W - imgSize.width * k) / 2
                let y0 = (H - imgSize.height * k) / 2
                let center = CGPoint(x: x0 + reactorCenter.x * k - ins.leading,
                                     y: y0 + reactorCenter.y * k - ins.top)
                let top = max(0, y0 + panelTop * k - ins.top)
                let side = max(14, x0 + panelSide * k - ins.leading)

                ZStack(alignment: .top) {
                    ReactorButton(diameter: reactorRing * k)
                        .position(center)

                    VStack(spacing: 0) {
                        statusLine
                        messages
                        if let route = assistant.lastRoute {
                            Button {
                                RouteService.shared.openInMaps(route)
                            } label: {
                                Label("Haritalar'da aç", systemImage: "car.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 16).padding(.vertical, 10)
                                    .background(Theme.accent.opacity(0.25), in: Capsule())
                                    .overlay(Capsule().stroke(Theme.glow.opacity(0.5), lineWidth: 1))
                            }
                            .padding(.bottom, 8)
                        }
                        if let err = assistant.errorText {
                            Text(err).font(.footnote).foregroundStyle(.orange)
                                .multilineTextAlignment(.center)
                                .padding(.bottom, 6)
                        }
                        inputBar
                    }
                    .padding(.top, top)
                    .padding(.horizontal, side)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .overlay(alignment: .topTrailing) { menu }
            }
        }
    }

    private var menu: some View {
        Group {
            if !store.messages.isEmpty {
                Menu {
                    Button("Sohbeti temizle", role: .destructive) { store.messages.removeAll() }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                        .foregroundStyle(Theme.glow.opacity(0.8))
                        .padding(12)
                }
            }
        }
    }

    private var statusLine: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                    .shadow(color: statusColor, radius: 4)
                Text(statusText.uppercased(with: Locale(identifier: "tr_TR")))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(Theme.glow.opacity(0.9))
            }
            Text(hint)
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .tracking(1)
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
        }
        .padding(.top, 6)
        .padding(.bottom, 4)
        .animation(.easeInOut, value: assistant.phase)
    }

    private var hint: String {
        if !assistant.conversing && assistant.phase == .idle {
            return "REAKTÖRE DOKUN · YA DA “HEY SİRİ, JARVIS”"
        }
        switch assistant.phase {
        case .listening: return "“BİTTİ” → İŞLE   ·   “JARVIS KAPAN” → ÇIK"
        case .thinking: return "İŞLENİYOR…"
        case .speaking: return "SUSTURMAK İÇİN DOKUN"
        case .idle: return ""
        }
    }

    private var statusColor: Color {
        switch assistant.phase {
        case .idle: return settings.isConfigured ? .green : .orange
        case .listening: return Theme.glow
        case .thinking: return .yellow
        case .speaking: return Theme.accent
        }
    }

    private var statusText: String {
        switch assistant.phase {
        case .idle: return settings.isConfigured ? "Hazır" : "Ayarlar'dan sunucuyu bağlayın"
        case .listening: return assistant.pendingNotes.isEmpty ? "Dinliyorum" : "Dinliyorum · \(assistant.pendingNotes.count) not"
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
                    ForEach(Array(assistant.pendingNotes.enumerated()), id: \.offset) { _, note in
                        PendingBubble(text: note)
                    }
                    if assistant.phase == .listening, !assistant.speech.partialText.isEmpty {
                        Bubble(message: ChatMessage(role: .user, text: assistant.speech.partialText))
                            .opacity(0.6)
                            .id("partial")
                    }
                }
                .padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.messages.count) { _, _ in
                if let last = store.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            .onChange(of: assistant.speech.partialText) { _, _ in
                proxy.scrollTo("partial", anchor: .bottom)
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
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.cardStroke, lineWidth: 1))
                .submitLabel(.send)
                .onSubmit(sendTyped)
            if !input.trimmingCharacters(in: .whitespaces).isEmpty {
                Button(action: sendTyped) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                }
                .disabled(assistant.phase == .thinking)
            }
        }
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
            Text("Reaktöre dokun ya da “Hey Siri, Jarvis” de. İstediğin kadar konuş; “bitti” deyince yaparım, soru sorarsan hemen cevaplarım. “Jarvis kapan” ile kapanırım.")
                .font(.footnote).foregroundStyle(.white.opacity(0.8))
            Text("Örnekler").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
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
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.cardStroke, lineWidth: 1))
        .padding(.top, 8)
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
                    message.role == .user ? Theme.accent.opacity(0.35) : Theme.card,
                    in: RoundedRectangle(cornerRadius: 18)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(message.role == .user ? Theme.glow.opacity(0.45) : Theme.cardStroke, lineWidth: 1)
                )
                .foregroundStyle(.white)
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }
}

/// Bekleyen (henüz "bitti" denmemiş) not
private struct PendingBubble: View {
    let text: String
    var body: some View {
        HStack {
            Spacer(minLength: 30)
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "hourglass").font(.caption2).foregroundStyle(Theme.glow.opacity(0.8))
                Text(text).font(.callout)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.glow.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .foregroundStyle(.white.opacity(0.75))
        }
    }
}

/// Arka plandaki reaktörün üzerine oturan konuşma düğmesi.
struct ReactorButton: View {
    @EnvironmentObject var assistant: Assistant
    let diameter: CGFloat
    @State private var breathe = false

    var body: some View {
        Button(action: assistant.toggleListening) {
            ZStack {
                // Çekirdek ışığı
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.9), Theme.glow, Theme.glow.opacity(0)],
                                         center: .center, startRadius: 0, endRadius: diameter * 0.32))
                    .frame(width: diameter * 0.62, height: diameter * 0.62)
                    .opacity(coreOpacity)
                    .scaleEffect(coreScale)
                    .blendMode(.screen)
                // Dönen halkalar (dinlerken / düşünürken / konuşurken)
                ReactorRings(phase: assistant.phase, level: assistant.speech.level)
                    .scaleEffect(diameter / 200)
                    .opacity(assistant.conversing || assistant.phase != .idle ? 1 : 0.0)
                // Dış parıltı
                Circle()
                    .stroke(Theme.glow.opacity(assistant.phase == .listening ? 0.7 : 0.0), lineWidth: 3)
                    .frame(width: diameter, height: diameter)
                    .blur(radius: 4)
                    .scaleEffect(breathe ? 1.04 : 0.98)
            }
            .frame(width: diameter * 1.25, height: diameter * 1.25)
            .contentShape(Circle())
            .animation(.easeInOut(duration: 0.4), value: assistant.phase)
            .animation(.easeOut(duration: 0.12), value: assistant.speech.level)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(assistant.conversing ? "Sohbeti bitir" : "Jarvis'le konuş")
        .onAppear {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { breathe = true }
        }
    }

    private var coreOpacity: Double {
        switch assistant.phase {
        case .idle: return breathe ? 0.25 : 0.12
        case .listening: return 0.55 + Double(assistant.speech.level) * 0.45
        case .thinking: return breathe ? 0.7 : 0.4
        case .speaking: return breathe ? 0.8 : 0.5
        }
    }

    private var coreScale: CGFloat {
        assistant.phase == .listening ? 0.9 + CGFloat(assistant.speech.level) * 0.35 : (breathe ? 1.0 : 0.92)
    }
}
