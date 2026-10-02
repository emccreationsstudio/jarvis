import SwiftUI

/// Koyu, ince ızgaralı, ortadan mavi ışık yayan "HUD" arka plan.
struct JarvisBackground: View {
    /// Işığın merkezi (0…1). Konuşma ekranında logonun olduğu yere iner.
    var focus: UnitPoint = .init(x: 0.5, y: 0.35)
    var intensity: Double = 1

    var body: some View {
        ZStack {
            Color(red: 0.008, green: 0.016, blue: 0.035)

            // Ana mavi ışık
            RadialGradient(
                colors: [Theme.glow.opacity(0.22 * intensity), Theme.accent.opacity(0.06 * intensity), .clear],
                center: focus, startRadius: 0, endRadius: 420
            )

            // İnce ızgara — kenarlara doğru kaybolur
            Canvas { ctx, size in
                let step: CGFloat = 28
                var path = Path()
                var x: CGFloat = 0
                while x <= size.width { path.move(to: .init(x: x, y: 0)); path.addLine(to: .init(x: x, y: size.height)); x += step }
                var y: CGFloat = 0
                while y <= size.height { path.move(to: .init(x: 0, y: y)); path.addLine(to: .init(x: size.width, y: y)); y += step }
                ctx.stroke(path, with: .color(Theme.glow.opacity(0.07)), lineWidth: 0.5)

                // Kesişimlerde küçük noktalar
                var dots = Path()
                x = 0
                while x <= size.width {
                    y = 0
                    while y <= size.height {
                        dots.addEllipse(in: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6))
                        y += step * 2
                    }
                    x += step * 2
                }
                ctx.fill(dots, with: .color(Theme.glow.opacity(0.18)))
            }
            .mask(
                RadialGradient(colors: [.white, .white.opacity(0.35), .clear], center: focus, startRadius: 40, endRadius: 520)
            )

            // Üst ve alt karartma
            LinearGradient(
                colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.6)],
                startPoint: .top, endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Logonun etrafında dönen, ark reaktörü tarzı halkalar.
struct ReactorRings: View {
    var phase: Assistant.Phase
    var level: Float

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let speed = speedFactor
            let boost = phase == .listening ? CGFloat(level) * 0.08 : 0
            ZStack {
                ring(diameter: 214, width: 1.2, dash: [2, 6], opacity: 0.35)
                    .rotationEffect(.degrees(t * 6 * speed))
                ring(diameter: 194, width: 2.5, dash: [44, 14, 8, 14], opacity: 0.55)
                    .rotationEffect(.degrees(-t * 14 * speed))
                arc(diameter: 176, from: 0.0, to: 0.22, width: 3, opacity: 0.9)
                    .rotationEffect(.degrees(t * 40 * speed))
                arc(diameter: 176, from: 0.5, to: 0.62, width: 3, opacity: 0.6)
                    .rotationEffect(.degrees(t * 40 * speed))
                // Tik işaretleri
                ForEach(0..<36, id: \.self) { i in
                    Capsule()
                        .fill(Theme.glow.opacity(i % 3 == 0 ? 0.5 : 0.18))
                        .frame(width: 1.2, height: i % 3 == 0 ? 7 : 4)
                        .offset(y: -116)
                        .rotationEffect(.degrees(Double(i) * 10))
                }
                .rotationEffect(.degrees(-t * 3 * speed))
            }
            .scaleEffect(1 + boost)
        }
        .frame(width: 240, height: 240)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.15), value: level)
    }

    private var speedFactor: Double {
        switch phase {
        case .idle: return 1
        case .listening: return 2.2
        case .thinking: return 4
        case .speaking: return 1.6
        }
    }

    private func ring(diameter: CGFloat, width: CGFloat, dash: [CGFloat], opacity: Double) -> some View {
        Circle()
            .stroke(Theme.glow.opacity(opacity), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
            .frame(width: diameter, height: diameter)
    }

    private func arc(diameter: CGFloat, from: CGFloat, to: CGFloat, width: CGFloat, opacity: Double) -> some View {
        Circle()
            .trim(from: from, to: to)
            .stroke(Theme.glow.opacity(opacity), style: StrokeStyle(lineWidth: width, lineCap: .round))
            .frame(width: diameter, height: diameter)
            .shadow(color: Theme.glow.opacity(0.8), radius: 6)
    }
}

// MARK: - Ortak arayüz parçaları (Listeler · Hafıza · Ayarlar)

/// Seçilen görsel, karartılmış ve hafif bulanık — diğer sekmelerin arka planı
struct HUDBackdrop: View {
    var dim: Double = 0.55
    var body: some View {
        GeometryReader { g in
            ZStack {
                Image("Backdrop")
                    .resizable()
                    .scaledToFill()
                    .frame(width: g.size.width, height: g.size.height)
                    .clipped()
                    .blur(radius: 2)
                Color.black.opacity(dim)
                LinearGradient(colors: [.black.opacity(0.35), .clear, .black.opacity(0.45)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Cam görünümlü satır / kart zemini
struct GlassRow: View {
    var radius: CGFloat = 14
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Theme.cardStroke, lineWidth: 1)
            )
            .padding(.vertical, 3)
    }
}

/// Bölüm başlığı: ince, aralıklı, mavi
struct HUDHeader: View {
    let text: String
    var body: some View {
        Text(text.uppercased(with: Locale(identifier: "tr_TR")))
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .tracking(2.5)
            .foregroundStyle(Theme.glow.opacity(0.85))
    }
}

/// Ekran başlığı (büyük, ışıklı)
struct HUDTitle: View {
    let text: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text.uppercased(with: Locale(identifier: "tr_TR")))
                .font(.system(size: 26, weight: .light, design: .monospaced))
                .tracking(6)
                .foregroundStyle(Theme.glow)
                .shadow(color: Theme.glow.opacity(0.6), radius: 8)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Parlayan ana düğme
struct HUDButtonStyle: ButtonStyle {
    var prominent = true
    var tint: Color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(
                Capsule().fill(prominent
                    ? AnyShapeStyle(LinearGradient(colors: [tint, tint.opacity(0.65)], startPoint: .top, endPoint: .bottom))
                    : AnyShapeStyle(Color.white.opacity(0.08)))
            )
            .overlay(Capsule().stroke(tint.opacity(prominent ? 0.9 : 0.5), lineWidth: 1))
            .shadow(color: prominent ? tint.opacity(0.55) : .clear, radius: configuration.isPressed ? 4 : 10)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Işıklı sekme seçici (Görevler · Alışveriş · Aranacak)
struct HUDSegmented: View {
    let items: [(title: String, icon: String, count: Int)]
    @Binding var selection: Int
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items.indices, id: \.self) { i in
                let selected = selection == i
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selection = i }
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: items[i].icon).font(.system(size: 12, weight: .semibold))
                        Text(items[i].title).font(.system(size: 13, weight: .semibold))
                        if items[i].count > 0 {
                            Text("\(items[i].count)")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(selected ? Color.white.opacity(0.25) : Theme.glow.opacity(0.2)))
                        }
                    }
                    .foregroundStyle(selected ? .white : .white.opacity(0.6))
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity)
                    .background {
                        if selected {
                            Capsule()
                                .fill(LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                                .shadow(color: Theme.glow.opacity(0.6), radius: 8)
                                .matchedGeometryEffect(id: "seg", in: ns)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Theme.cardStroke, lineWidth: 1))
    }
}

/// Liste satırlarına cam zemin + ayraçsız görünüm
extension View {
    func glassRow() -> some View {
        self
            .listRowBackground(GlassRow())
            .listRowSeparator(.hidden)
    }
}

/// Klavyenin ekranda kapladığı yükseklik (iOS 26 sekme ekranlarında içerik kendiliğinden kaymadığı için)
@MainActor
final class KeyboardObserver: ObservableObject {
    @Published private(set) var height: CGFloat = 0
    private var tokens: [NSObjectProtocol] = []

    init() {
        let nc = NotificationCenter.default
        tokens.append(nc.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let screen = UIScreen.main.bounds.height
            let overlap = max(0, screen - frame.minY)
            Task { @MainActor in self?.height = overlap }
        })
        tokens.append(nc.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.height = 0 }
        })
    }

    deinit {
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
    }
}
