import SwiftUI

struct MemoryView: View {
    @EnvironmentObject var store: Store
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                HUDTitle(text: "Hafıza", subtitle: store.memory.isEmpty ? "Jarvis henüz bir şey ezberlemedi" : "\(store.memory.count) kayıt · her konuşmada dikkate alınır")
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                List {
                    Section {
                        HStack(spacing: 10) {
                            Image(systemName: "brain.head.profile").foregroundStyle(Theme.glow.opacity(0.8))
                            TextField("", text: $text, prompt: Text("Jarvis neyi hatırlasın?").foregroundColor(.white.opacity(0.4)), axis: .vertical)
                            Button(action: add) {
                                Image(systemName: "plus")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 30, height: 30)
                                    .background(Circle().fill(canAdd ? Theme.accent : Color.white.opacity(0.1)))
                                    .shadow(color: canAdd ? Theme.glow.opacity(0.6) : .clear, radius: 6)
                            }
                            .buttonStyle(.plain)
                            .disabled(!canAdd)
                        }
                        .padding(.vertical, 2)
                        .glassRow()
                    } footer: {
                        Text("Konuşurken \"bunu hatırla\" demen de yeterli.")
                            .font(.caption2).foregroundStyle(.white.opacity(0.4))
                    }
                    Section {
                        if store.memory.isEmpty {
                            HStack(spacing: 12) {
                                Image(systemName: "sparkles").foregroundStyle(Theme.glow.opacity(0.5))
                                Text("Örnek: \"Pazartesi ve perşembe stüdyom var\", \"Bostancı'daki müşteri Ahmet Bey\"")
                                    .font(.subheadline).foregroundStyle(.white.opacity(0.55))
                            }
                            .padding(.vertical, 6)
                            .glassRow()
                        }
                        ForEach(store.memory.reversed()) { note in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "bookmark.fill").font(.caption).foregroundStyle(Theme.glow).padding(.top, 3)
                                Text(note.text).foregroundStyle(.white)
                            }
                            .padding(.vertical, 4)
                            .glassRow()
                        }
                        .onDelete { offsets in
                            let reversed = Array(store.memory.reversed())
                            let ids = Set(offsets.map { reversed[$0].id })
                            store.memory.removeAll { ids.contains($0.id) }
                        }
                    } header: {
                        if !store.memory.isEmpty { HUDHeader(text: "Bildikleri") }
                    }
                }
                .scrollContentBackground(.hidden)
                .listRowSpacing(6)
            }
            .background(Theme.background)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var canAdd: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func add() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        store.memory.append(MemoryNote(text: t))
        text = ""
    }
}

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var assistant: Assistant
    @State private var testResult: String?
    @State private var testing = false
    @State private var alarmResult: String?

    private var toneLabel: String {
        switch settings.voiceTone {
        case ..<0.13: return "Çok kalın"
        case ..<0.38: return "Kalın"
        case ..<0.63: return "Orta"
        case ..<0.88: return "İnce"
        default: return "Çok ince"
        }
    }

    private var speedLabel: String {
        switch settings.voiceSpeed {
        case ..<0.93: return "Yavaş"
        case ..<1.12: return "Normal"
        case ..<1.27: return "Hızlı"
        default: return "Çok hızlı"
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                HUDTitle(text: "Ayarlar", subtitle: settings.isConfigured ? "Sunucu bağlı" : "Sunucu bağlı değil")
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                Form {
                    Section {
                        TextField("https://jarvis.….workers.dev", text: $settings.serverURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Uygulama şifresi", text: $settings.token)
                        Button {
                            testing = true
                            Task {
                                testResult = await assistant.testConnection()
                                testing = false
                            }
                        } label: {
                            HStack(spacing: 8) {
                                if testing { ProgressView().tint(.white) } else { Image(systemName: "bolt.horizontal.circle") }
                                Text("Bağlantıyı test et")
                            }
                        }
                        .buttonStyle(HUDButtonStyle())
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                        if let testResult {
                            Text(testResult).font(.footnote).foregroundStyle(.white.opacity(0.6))
                        }
                    } header: {
                        HUDHeader(text: "Sunucu")
                    } footer: {
                        Text("Cloudflare'deki Jarvis sunucusunun adresi ve APP_TOKEN şifresi.")
                            .font(.caption2).foregroundStyle(.white.opacity(0.4))
                    }
                    .glassRow()

                    Section {
                        Toggle("Doğal ses (yapay zekâ)", isOn: $settings.naturalVoice)
                        if settings.naturalVoice {
                            Picker("Ses", selection: $settings.voiceFemale) {
                                Text("Erkek").tag(false)
                                Text("Kadın").tag(true)
                            }
                            .pickerStyle(.segmented)
                        }
                        Group {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Ton")
                                    Spacer()
                                    Text(toneLabel).foregroundStyle(.white.opacity(0.6))
                                }
                                HStack(spacing: 8) {
                                    Text("Kalın").font(.caption2).foregroundStyle(.white.opacity(0.5))
                                    Slider(value: $settings.voiceTone, in: 0...1, step: 0.25).tint(Theme.glow)
                                    Text("İnce").font(.caption2).foregroundStyle(.white.opacity(0.5))
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Konuşma hızı")
                                Spacer()
                                Text(speedLabel).foregroundStyle(.white.opacity(0.6))
                            }
                            HStack(spacing: 8) {
                                Image(systemName: "tortoise.fill").font(.caption).foregroundStyle(.white.opacity(0.5))
                                Slider(value: $settings.voiceSpeed, in: 0.8...1.4, step: 0.05).tint(Theme.glow)
                                Image(systemName: "hare.fill").font(.caption).foregroundStyle(.white.opacity(0.5))
                            }
                        }
                        Toggle("Cevapları sesli oku", isOn: $settings.speakReplies)
                        Button {
                            assistant.speech.speak("Merhaba \(settings.userName), ben \(settings.assistantName). Bugün senin için ne yapabilirim?")
                        } label: {
                            Label("Sesi dene", systemImage: "speaker.wave.2.fill")
                        }
                        .buttonStyle(HUDButtonStyle(prominent: false))
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                    } header: {
                        HUDHeader(text: "Ses")
                    } footer: {
                        Text(settings.naturalVoice
                             ? "Doğal ses, cevabı sunucu üzerinden insan gibi seslendirir. İnternet yoksa iPhone sesine geçer."
                             : "iPhone sesi kullanılıyor. Daha iyi bir iPhone sesi için: Ayarlar → Erişilebilirlik → Seslendirilen İçerik → Sesler → Türkçe → Yelda (Gelişmiş) indir.")
                            .font(.caption2).foregroundStyle(.white.opacity(0.4))
                    }
                    .glassRow()

                    Section {
                        Toggle("Tüm hatırlatmalar alarm gibi çalsın", isOn: $settings.alarmAll)
                        Button {
                            Task { alarmResult = await Reminders.shared.testAlarm() }
                        } label: {
                            Label("Alarmı dene (10 sn)", systemImage: "alarm.fill")
                        }
                        .buttonStyle(HUDButtonStyle(prominent: false, tint: .orange))
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                        if let alarmResult {
                            Text(alarmResult).font(.footnote).foregroundStyle(.white.opacity(0.6))
                        }
                    } header: {
                        HUDHeader(text: "Hatırlatmalar")
                    } footer: {
                        Text("Alarm: sessiz modda bile çalar ve titreşir, kilit ekranında büyük gösterilir. Kapalıysa yalnızca önemli ve kritik işler alarm olur; düşük önemliler her zaman sessiz bildirimdir.")
                            .font(.caption2).foregroundStyle(.white.opacity(0.4))
                    }
                    .glassRow()

                    Section {
                        TextField("Adın", text: $settings.userName)
                        TextField("Asistanın adı", text: $settings.assistantName)
                        Toggle("Açılınca hemen dinlemeye başla", isOn: $settings.autoListen)
                    } header: {
                        HUDHeader(text: "Kişisel")
                    }
                    .glassRow()

                    Section {
                        Button {
                            Task { await assistant.requestAllPermissions() }
                        } label: { Label("Tüm izinleri iste", systemImage: "checkmark.shield") }
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        } label: { Label("iPhone Ayarlarını aç", systemImage: "gearshape") }
                    } header: {
                        HUDHeader(text: "İzinler")
                    } footer: {
                        Text("Mikrofon, konuşma tanıma, bildirimler, alarmlar, takvim, konum ve rehber.")
                            .font(.caption2).foregroundStyle(.white.opacity(0.4))
                    }
                    .glassRow()

                    Section {
                        Label("\"Hey Siri, Jarvis\" deyin: açılır, \"Efendim?\" der ve dinler.", systemImage: "mic.circle")
                        Label("Sol alttaki Jarvis düğmesi ya da reaktör: dinlemeyi yeniden açar.", systemImage: "hand.tap")
                        Label("Arkaya Dokunma: Ayarlar → Erişilebilirlik → Dokunma → Arkaya Dokunma → Çift Dokunma → Jarvis.", systemImage: "iphone.gen3")
                    } header: {
                        HUDHeader(text: "Hızlı erişim")
                    }
                    .font(.footnote)
                    .glassRow()
                }
                .scrollContentBackground(.hidden)
                .listRowSpacing(6)
            }
            .background(Theme.background)
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

struct OnboardingView: View {
    @EnvironmentObject var assistant: Assistant
    let done: () -> Void
    @State private var working = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                Image("Orb").resizable().scaledToFit().frame(width: 140, height: 140).clipShape(Circle())
                    .shadow(color: Theme.glow.opacity(0.6), radius: 30)
                Text("Merhaba, ben Jarvis").font(.title.bold())
                VStack(alignment: .leading, spacing: 14) {
                    row("mic.fill", "Konuşarak görev, alışveriş ve arama listesi tut")
                    row("alarm.fill", "Önemli işlerde alarm gibi hatırlatayım")
                    row("calendar", "Takvimini ve trafiği dikkate alıp gününü planlayayım")
                    row("lock.fill", "Listelerin telefonunda kalır; konuşmaların yalnızca cevap üretmek için yapay zekâ servisine (OpenAI) gönderilir")
                }
                .font(.subheadline)
                .padding(.horizontal, 28)
                Spacer()
                Button {
                    working = true
                    Task {
                        await assistant.requestAllPermissions()
                        working = false
                        done()
                    }
                } label: {
                    HStack { if working { ProgressView().tint(.white) }; Text("İzinleri ver ve başla").bold() }
                }
                .buttonStyle(HUDButtonStyle())
                .padding(.horizontal, 24)
                .disabled(working)
                Button("Şimdilik geç", action: done).font(.footnote).foregroundStyle(.secondary).padding(.bottom, 20)
            }
        }
        .interactiveDismissDisabled()
    }

    private func row(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 24)
            Text(text)
        }
    }
}
