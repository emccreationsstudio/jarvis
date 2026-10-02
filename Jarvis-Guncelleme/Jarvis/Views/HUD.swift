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
