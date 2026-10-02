import SwiftUI

struct MemoryView: View {
    @EnvironmentObject var store: Store
    @State private var text = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Jarvis neyi hatırlasın?", text: $text, axis: .vertical)
                        Button {
                            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !t.isEmpty else { return }
                            store.memory.append(MemoryNote(text: t))
                            text = ""
                        } label: { Image(systemName: "plus.circle.fill").font(.title2) }
                    }
                } footer: {
                    Text("Jarvis buradaki bilgileri her konuşmada dikkate alır. Konuşurken \"bunu hatırla\" demen de yeterli.")
                }
                Section {
                    if store.memory.isEmpty {
                        Text("Henüz kayıt yok.").foregroundStyle(.secondary)
                    }
                    ForEach(store.memory.reversed()) { note in
                        Text(note.text)
                    }
                    .onDelete { offsets in
                        let reversed = Array(store.memory.reversed())
                        let ids = Set(offsets.map { reversed[$0].id })
                        store.memory.removeAll { ids.contains($0.id) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Hafıza")
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var assistant: Assistant
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        NavigationStack {
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
                        HStack {
                            Text("Bağlantıyı test et")
                            if testing { Spacer(); ProgressView() }
                        }
                    }
                    if let testResult {
                        Text(testResult).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Sunucu")
                } footer: {
                    Text("Cloudflare'de kurduğunuz Jarvis sunucusunun adresi ve orada APP_TOKEN olarak girdiğiniz şifre.")
                }

                Section("Kişisel") {
                    TextField("Adın", text: $settings.userName)
                    TextField("Asistanın adı", text: $settings.assistantName)
                    Toggle("Cevapları sesli oku", isOn: $settings.speakReplies)
                }

                Section {
                    Button("Tüm izinleri iste") {
                        Task { await assistant.requestAllPermissions() }
                    }
                    Button("iPhone Ayarlarını aç") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                } header: {
                    Text("İzinler")
                } footer: {
                    Text("Mikrofon, konuşma tanıma, bildirimler, alarmlar, takvim, konum ve rehber.")
                }

                Section("Jarvis'i hızlı açmak") {
                    Label("\"Hey Siri, Jarvis\" deyin: açılır ve dinlemeye başlar.", systemImage: "mic.circle")
                    Label("\"Hey Siri, Jarvis'e söyle\": söylediğinizi doğrudan iletir.", systemImage: "text.bubble")
                    Label("Arkaya Dokunma: Ayarlar → Erişilebilirlik → Dokunma → Arkaya Dokunma → Çift Dokunma → \"Jarvis'i Dinlet\".", systemImage: "hand.tap")
                }
                .font(.footnote)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Ayarlar")
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
                        .frame(maxWidth: .infinity).padding()
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(.white)
                }
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
