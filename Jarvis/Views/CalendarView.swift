import SwiftUI
import UIKit

/// Takvim sekmesinin sayfaları (Jarvis "takvimi göster" diyerek de açabilir)
enum CalendarPage: String, CaseIterable {
    case week, year, moments
}

/// Pazartesi ile başlayan Türkçe takvim
private let trCal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.locale = Locale(identifier: "tr_TR")
    c.timeZone = .current
    c.firstWeekday = 2
    return c
}()

private let trLocale = Locale(identifier: "tr_TR")

struct CalendarTab: View {
    @EnvironmentObject var store: Store
    @Binding var page: CalendarPage
    /// "Haftamı planla" → Jarvis sekmesine geçip isteği gönderir
    var askJarvis: (String) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HUDTitle(text: "Takvim", subtitle: subtitle)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                HUDSegmented(items: [
                    ("Hafta", "calendar.day.timeline.left", 0),
                    ("Yıl", "calendar", store.specials.count),
                    ("Anılar", "sparkles", store.moments.count)
                ], selection: Binding(
                    get: { CalendarPage.allCases.firstIndex(of: page) ?? 0 },
                    set: { page = CalendarPage.allCases[$0] }
                ))
                .padding(.horizontal, 16)

                switch page {
                case .week: WeekPage(askJarvis: askJarvis)
                case .year: YearPage()
                case .moments: MomentsPage()
                }
            }
            .background(Theme.background)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var subtitle: String {
        let now = Date()
        if let next = store.specials.min(by: { $0.next(from: now) < $1.next(from: now) }) {
            let days = trCal.dateComponents([.day], from: trCal.startOfDay(for: now), to: next.next(from: now)).day ?? 0
            if days == 0 { return "Bugün: \(next.title)" }
            if days <= 30 { return "\(days) gün sonra: \(next.title)" }
        }
        return DateText.long(now)
    }
}

// MARK: - Hafta

private struct WeekPage: View {
    @EnvironmentObject var store: Store
    var askJarvis: (String) -> Void
    @State private var offset = 0
    @State private var events: [CalendarService.Event] = []
    @State private var editingEvent: CalendarService.Event?
    @State private var editingTask: TaskItem?
    @State private var addingOn: AddDay?
    @State private var deletingEvent: CalendarService.Event?

    private var weekStart: Date {
        let base = trCal.dateInterval(of: .weekOfYear, for: Date())?.start ?? trCal.startOfDay(for: Date())
        return trCal.date(byAdding: .weekOfYear, value: offset, to: base) ?? base
    }

    private var days: [Date] {
        (0..<7).compactMap { trCal.date(byAdding: .day, value: $0, to: weekStart) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                HStack {
                    Button { offset -= 1 } label: { Image(systemName: "chevron.left").padding(10) }
                    Spacer()
                    VStack(spacing: 2) {
                        Text(rangeText).font(.system(size: 15, weight: .semibold))
                        Text(offset == 0 ? "Bu hafta" : offset == 1 ? "Gelecek hafta" : offset == -1 ? "Geçen hafta" : "")
                            .font(.caption2).foregroundStyle(Theme.glow.opacity(0.8))
                    }
                    Spacer()
                    Button { offset += 1 } label: { Image(systemName: "chevron.right").padding(10) }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 4)

                Button {
                    askJarvis(offset == 0 ? "Bu haftamı planla" : "Gelecek haftamı planla")
                } label: {
                    Label("Jarvis haftamı planlasın", systemImage: "wand.and.stars")
                }
                .buttonStyle(HUDButtonStyle())

                Button {
                    addingOn = AddDay(date: trCal.isDate(Date(), equalTo: weekStart, toGranularity: .weekOfYear) ? Date() : weekStart)
                } label: {
                    Label("Etkinlik ya da hatırlatma ekle", systemImage: "plus.circle.fill")
                }
                .buttonStyle(HUDButtonStyle())

                ForEach(days, id: \.self) { day in
                    DayCard(day: day, events: events.filter { trCal.isDate($0.start, inSameDayAs: day) },
                            onEvent: { editingEvent = $0 }, onTask: { editingTask = $0 },
                            onAdd: { addingOn = AddDay(date: day) },
                            onDeleteEvent: { deletingEvent = $0 })
                }
                Text("Etkinliğe ya da göreve dokun: düzenle, ertele. Sola kaydırınca silinir. Basılı tutunca hızlı menü açılır, günün yanındaki + ile o güne ekle. Jarvis'e \"yarınki toplantıyı 3'e al\" da diyebilirsin.")
                    .font(.caption2).foregroundStyle(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
                if !CalendarService.shared.hasAccess {
                    Text("Telefon takvimindeki etkinlikleri de görmek için Ayarlar → İzinler'den takvim iznini ver.")
                        .font(.caption).foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 90)
        }
        .scrollIndicators(.hidden)
        .onAppear(perform: load)
        .onChange(of: offset) { _, _ in load() }
        .sheet(item: $editingEvent, onDismiss: load) { e in EventEditor(event: e) }
        .sheet(item: $editingTask) { t in TaskEditor(task: t) }
        .sheet(item: $addingOn, onDismiss: load) { d in AddEventSheet(day: d.date) }
        .confirmationDialog("“\(deletingEvent?.title ?? "")” silinsin mi?",
                            isPresented: Binding(get: { deletingEvent != nil }, set: { if !$0 { deletingEvent = nil } }),
                            titleVisibility: .visible) {
            Button("Etkinliği sil", role: .destructive) {
                guard let id = deletingEvent?.id else { return }
                Task { _ = await CalendarService.shared.delete(id: id); deletingEvent = nil; load() }
            }
        } message: {
            Text("Telefon takviminden silinir.")
        }
    }

    private var rangeText: String {
        guard let last = days.last else { return "" }
        let f = Date.FormatStyle.dateTime.day().month(.abbreviated).locale(trLocale)
        return "\(weekStart.formatted(f)) – \(last.formatted(f))"
    }

    private func load() {
        let end = trCal.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
        events = CalendarService.shared.events(from: weekStart, to: end)
    }
}

private struct DayCard: View {
    @EnvironmentObject var store: Store
    let day: Date
    let events: [CalendarService.Event]
    var onEvent: (CalendarService.Event) -> Void = { _ in }
    var onTask: (TaskItem) -> Void = { _ in }
    var onAdd: () -> Void = {}
    var onDeleteEvent: (CalendarService.Event) -> Void = { _ in }

    var body: some View {
        let holidays = Holiday.between(day, day)
        let specials = store.specials(on: day)
        let moments = store.moments(on: day)
        let tasks = store.tasks(on: day)
        let isToday = trCal.isDateInToday(day)
        let empty = holidays.isEmpty && specials.isEmpty && moments.isEmpty && tasks.isEmpty && events.isEmpty

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(day.formatted(.dateTime.weekday(.wide).locale(trLocale)).capitalized(with: trLocale))
                    .font(.system(size: 15, weight: .semibold))
                Text(day.formatted(.dateTime.day().month(.wide).locale(trLocale)))
                    .font(.caption).foregroundStyle(.white.opacity(0.55))
                Spacer()
                Button(action: onAdd) {
                    Image(systemName: "plus.circle").font(.system(size: 17)).foregroundStyle(Theme.glow)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Bu güne ekle")
                if isToday {
                    Text("BUGÜN")
                        .font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.5)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Theme.accent))
                        .shadow(color: Theme.glow.opacity(0.7), radius: 6)
                }
            }
            if empty {
                Text("Boş gün").font(.caption).foregroundStyle(.white.opacity(0.35))
            }
            ForEach(holidays) { h in
                Chip(icon: h.icon, color: h.color, text: h.title)
            }
            ForEach(specials) { s in
                Chip(icon: s.kind.icon, color: s.kind.color,
                     text: s.title + (s.years(on: day).map { " · \($0). \(s.kind == .birthday ? "yaş" : "yıl")" } ?? ""))
            }
            ForEach(Array(events.enumerated()), id: \.offset) { _, e in
                AgendaRow(time: e.end == nil ? "Tüm gün" : e.start.formatted(.dateTime.hour().minute().locale(trLocale)),
                          title: e.title, detail: e.location, color: Theme.glow, icon: "calendar")
                    .contentShape(Rectangle())
                    .onTapGesture { if e.id != nil { onEvent(e) } }
                    .modifier(SwipeToDelete(enabled: e.id != nil && e.editable) { onDeleteEvent(e) })
                    .contextMenu {
                        if e.id != nil {
                            Button { onEvent(e) } label: { Label(e.editable ? "Düzenle / ertele" : "Aç", systemImage: "pencil") }
                            if e.editable {
                                Button(role: .destructive) { onDeleteEvent(e) } label: { Label("Sil", systemImage: "trash") }
                            }
                        }
                    }
            }
            ForEach(tasks) { t in
                AgendaRow(time: t.due.map { $0.formatted(.dateTime.hour().minute().locale(trLocale)) } ?? "",
                          title: t.title, detail: t.done ? "Tamamlandı" : nil,
                          color: Theme.color(for: t.priority),
                          icon: t.done ? "checkmark.circle.fill" : (t.priority == .critical ? "alarm.fill" : "circle"))
                    .opacity(t.done ? 0.5 : 1)
                    .contentShape(Rectangle())
                    .onTapGesture { onTask(t) }
                    .modifier(SwipeToDelete { store.delete(taskID: t.id) })
                    .contextMenu {
                        Button { onTask(t) } label: { Label("Düzenle / ertele", systemImage: "pencil") }
                        Button {
                            var x = t; x.done.toggle(); x.doneAt = x.done ? Date() : nil; store.upsert(x)
                        } label: { Label(t.done ? "Yapılmadı say" : "Tamamlandı", systemImage: "checkmark.circle") }
                        Button(role: .destructive) { store.delete(taskID: t.id) } label: { Label("Sil", systemImage: "trash") }
                    }
            }
            ForEach(moments) { m in
                Chip(icon: "sparkles", color: .cyan, text: "Anı: " + m.title)
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GlassRow(radius: 16).padding(.vertical, -3))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isToday ? Theme.glow.opacity(0.7) : .clear, lineWidth: 1.2)
        )
    }
}

/// 1.3.1: Sola kaydır → kırmızı çöp düğmesi çıkar (dokununca siler); sonuna kadar kaydırınca doğrudan siler.
/// Takvim etkinliğinde yine "silinsin mi?" diye sorulur; hatırlatmalar çöp kutusuna gider (geri alınabilir).
private struct SwipeToDelete: ViewModifier {
    var enabled: Bool = true
    var onDelete: () -> Void
    @State private var offset: CGFloat = 0
    @State private var start: CGFloat = 0
    @State private var horizontal: Bool?
    private let reveal: CGFloat = 72
    private let fullSwipe: CGFloat = 190

    func body(content: Content) -> some View {
        ZStack(alignment: .trailing) {
            if offset < 0 {
                Button {
                    withAnimation(.spring(duration: 0.25)) { offset = 0; start = 0 }
                    onDelete()
                } label: {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: max(reveal, -offset))
                        .frame(maxHeight: .infinity)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.red))
                }
                .buttonStyle(.plain)
                .frame(width: -offset)
                .clipped()
                .accessibilityLabel("Sil")
            }
            content.offset(x: offset)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 14)
                .onChanged { v in
                    if horizontal == nil { horizontal = abs(v.translation.width) > abs(v.translation.height) * 1.3 }
                    guard horizontal == true else { return }
                    offset = min(0, start + v.translation.width)
                }
                .onEnded { _ in
                    defer { horizontal = nil }
                    guard horizontal == true else { return }
                    if offset < -fullSwipe {
                        withAnimation(.spring(duration: 0.25)) { offset = 0; start = 0 }
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        onDelete()
                    } else {
                        withAnimation(.spring(duration: 0.25)) { offset = offset < -reveal / 2 ? -reveal : 0 }
                        start = offset
                    }
                },
            including: enabled ? .all : .subviews
        )
    }
}

private struct Chip: View {
    let icon: String
    let color: Color
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption)
            Text(text).font(.caption.weight(.semibold)).lineLimit(2)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.15)))
        .overlay(Capsule().stroke(color.opacity(0.45), lineWidth: 0.8))
    }
}

private struct AgendaRow: View {
    let time: String
    let title: String
    let detail: String?
    let color: Color
    let icon: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(time)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 54, alignment: .leading)
            Capsule().fill(color).frame(width: 3).shadow(color: color.opacity(0.8), radius: 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.caption2).foregroundStyle(color)
                    Text(title).font(.subheadline)
                }
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.white.opacity(0.5))
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Yıl

private struct YearPage: View {
    @EnvironmentObject var store: Store
    @State private var year = trCal.component(.year, from: Date())
    @State private var selectedMonth: Int? = trCal.component(.month, from: Date())
    @State private var adding = false

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack {
                    Button { year -= 1 } label: { Image(systemName: "chevron.left").padding(10) }
                    Spacer()
                    Text(String(year)).font(.system(size: 20, weight: .light, design: .monospaced)).tracking(4)
                    Spacer()
                    Button { year += 1 } label: { Image(systemName: "chevron.right").padding(10) }
                }
                .foregroundStyle(.white)

                Legend()

                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(1...12, id: \.self) { m in
                        MonthMini(year: year, month: m, selected: selectedMonth == m)
                            .onTapGesture { withAnimation { selectedMonth = (selectedMonth == m ? nil : m) } }
                    }
                }

                if let m = selectedMonth {
                    MonthDetail(year: year, month: m)
                }

                HStack {
                    HUDHeader(text: "Özel günlerim")
                    Spacer()
                    Button { adding = true } label: {
                        Label("Ekle", systemImage: "plus").font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(Theme.glow)
                }
                .padding(.top, 6)

                if store.specials.isEmpty {
                    Text("Henüz özel gün yok. Jarvis'e \"Annemin doğum günü 3 Mart\" diyebilir ya da Ekle'ye basabilirsin.")
                        .font(.caption).foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(store.specials.sorted { $0.next() < $1.next() }) { s in
                    let next = s.next()
                    HStack(spacing: 12) {
                        Image(systemName: s.kind.icon).foregroundStyle(s.kind.color)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(s.kind.color.opacity(0.15)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.title).foregroundStyle(.white)
                            Text(DateText.dayMonth(next) + (s.years(on: next).map { " · \($0). \(s.kind == .birthday ? "yaş" : "yıl")" } ?? ""))
                                .font(.caption).foregroundStyle(.white.opacity(0.55))
                        }
                        Spacer()
                        Text(daysLeft(next)).font(.caption.weight(.semibold)).foregroundStyle(Theme.glow)
                    }
                    .padding(12)
                    .background(GlassRow(radius: 14).padding(.vertical, -3))
                    .contextMenu {
                        Button(role: .destructive) { store.removeSpecial(id: s.id) } label: { Label("Sil", systemImage: "trash") }
                    }
                }
                Text("Silmek için basılı tut.").font(.caption2).foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 90)
        }
        .scrollIndicators(.hidden)
        .sheet(isPresented: $adding) { AddSpecialSheet() }
    }

    private func daysLeft(_ d: Date) -> String {
        let n = trCal.dateComponents([.day], from: trCal.startOfDay(for: Date()), to: d).day ?? 0
        return n == 0 ? "Bugün" : n == 1 ? "Yarın" : "\(n) gün"
    }
}

private struct Legend: View {
    var body: some View {
        HStack(spacing: 12) {
            dot(.pink, "Özel gün")
            dot(.red, "Resmî")
            dot(.green, "Dini")
            dot(.purple, "Kutlama")
            dot(.cyan, "Anı")
        }
        .font(.system(size: 10))
        .foregroundStyle(.white.opacity(0.6))
    }
    private func dot(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { Circle().fill(c).frame(width: 6, height: 6); Text(t) }
    }
}

/// Bir günün işaret renkleri
@MainActor
private func marks(for date: Date, store: Store, holidays: [Holiday]) -> [Color] {
    var out: [Color] = []
    if !store.specials(on: date).isEmpty { out.append(.pink) }
    for h in holidays where trCal.isDate(h.date, inSameDayAs: date) {
        if !out.contains(h.color) { out.append(h.color) }
    }
    if !store.moments(on: date).isEmpty { out.append(.cyan) }
    return out
}

private struct MonthMini: View {
    @EnvironmentObject var store: Store
    let year: Int
    let month: Int
    let selected: Bool

    var body: some View {
        let first = trCal.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date()
        let count = trCal.range(of: .day, in: .month, for: first)?.count ?? 30
        let lead = (trCal.component(.weekday, from: first) + 5) % 7   // pazartesi = 0
        let holidays = Holiday.list(year: year)
        let cols = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

        VStack(alignment: .leading, spacing: 6) {
            Text(first.formatted(.dateTime.month(.wide).locale(trLocale)).capitalized(with: trLocale))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? Theme.glow : .white)
            LazyVGrid(columns: cols, spacing: 3) {
                ForEach(0..<(lead + count), id: \.self) { i in
                    if i < lead {
                        Color.clear.frame(height: 16)
                    } else {
                        DayDot(year: year, month: month, day: i - lead + 1, holidays: holidays)
                    }
                }
            }
        }
        .padding(10)
        .background(GlassRow(radius: 12).padding(.vertical, -3))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Theme.glow.opacity(0.7) : .clear, lineWidth: 1))
    }
}

/// Yıllık görünümde tek gün: numara + renkli işaret noktaları
private struct DayDot: View {
    @EnvironmentObject var store: Store
    let year: Int
    let month: Int
    let day: Int
    let holidays: [Holiday]

    var body: some View {
        let date = trCal.date(from: DateComponents(year: year, month: month, day: day)) ?? Date()
        let colors = marks(for: date, store: store, holidays: holidays)
        let today = trCal.isDateInToday(date)
        VStack(spacing: 1) {
            Text("\(day)")
                .font(.system(size: 8, weight: today ? .bold : .regular))
                .foregroundStyle(today ? Color.white : Color.white.opacity(colors.isEmpty ? 0.45 : 0.95))
                .frame(width: 14, height: 11)
                .background(Circle().fill(today ? Theme.accent : Color.clear).frame(width: 13, height: 13))
            HStack(spacing: 1) {
                ForEach(Array(colors.prefix(3).enumerated()), id: \.offset) { _, c in
                    Circle().fill(c).frame(width: 3, height: 3)
                }
            }
            .frame(height: 3)
        }
        .frame(height: 16)
    }
}

/// Seçilen ayın işaretli günleri
private struct MonthDetail: View {
    @EnvironmentObject var store: Store
    let year: Int
    let month: Int

    private struct Item: Identifiable {
        let id = UUID()
        let date: Date
        let icon: String
        let color: Color
        let text: String
    }

    var body: some View {
        let items = collect()
        VStack(alignment: .leading, spacing: 8) {
            if items.isEmpty {
                Text("Bu ayda işaretli gün yok.").font(.caption).foregroundStyle(.white.opacity(0.5))
            }
            ForEach(items) { it in
                HStack(spacing: 10) {
                    Text(it.date.formatted(.dateTime.day().locale(trLocale)))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .frame(width: 26)
                        .foregroundStyle(.white)
                    Image(systemName: it.icon).font(.caption).foregroundStyle(it.color)
                    Text(it.text).font(.subheadline).foregroundStyle(.white)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GlassRow(radius: 14).padding(.vertical, -3))
    }

    private func collect() -> [Item] {
        var out: [Item] = []
        for h in Holiday.list(year: year) where trCal.component(.month, from: h.date) == month {
            out.append(Item(date: h.date, icon: h.icon, color: h.color, text: h.title))
        }
        for s in store.specials where s.month == month {
            if let d = trCal.date(from: DateComponents(year: year, month: s.month, day: s.day)) {
                out.append(Item(date: d, icon: s.kind.icon, color: s.kind.color,
                                text: s.title + (s.years(on: d).map { " · \($0). \(s.kind == .birthday ? "yaş" : "yıl")" } ?? "")))
            }
        }
        for m in store.moments where trCal.component(.year, from: m.date) == year && trCal.component(.month, from: m.date) == month {
            out.append(Item(date: m.date, icon: "sparkles", color: .cyan, text: m.title))
        }
        return out.sorted { $0.date < $1.date }
    }
}

// MARK: - Anılar

private struct MomentsPage: View {
    @EnvironmentObject var store: Store
    @State private var adding = false

    private var byYear: [(year: Int, items: [Moment])] {
        let groups = Dictionary(grouping: store.moments) { trCal.component(.year, from: $0.date) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!.sorted { $0.date > $1.date }) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Button { adding = true } label: { Label("Anı ekle", systemImage: "plus") }
                    .buttonStyle(HUDButtonStyle())

                if store.moments.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Henüz anı yok.").font(.subheadline).foregroundStyle(.white)
                        Text("Jarvis'e anlatman yeterli: \"1 Ekim'de Harbiye'de konuk sanatçı olarak sahneye çıktım.\" Senin için saklarım.")
                            .font(.caption).foregroundStyle(.white.opacity(0.55))
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GlassRow(radius: 14).padding(.vertical, -3))
                }

                ForEach(byYear, id: \.year) { group in
                    HUDHeader(text: String(group.year)).padding(.top, 4)
                    ForEach(group.items) { m in
                        MomentCard(moment: m)
                            .contextMenu {
                                Button(role: .destructive) { store.moments.removeAll { $0.id == m.id } } label: { Label("Sil", systemImage: "trash") }
                            }
                    }
                }

                Text("Yakında: anılarına fotoğraflarını da ekleyebileceksin.")
                    .font(.caption2).foregroundStyle(.white.opacity(0.35))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 90)
        }
        .scrollIndicators(.hidden)
        .sheet(isPresented: $adding) { AddMomentSheet() }
    }
}

private struct MomentCard: View {
    let moment: Moment
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Text(moment.date.formatted(.dateTime.day().locale(trLocale)))
                    .font(.system(size: 20, weight: .light, design: .monospaced))
                Text(moment.date.formatted(.dateTime.month(.abbreviated).locale(trLocale)).uppercased(with: trLocale))
                    .font(.system(size: 9, weight: .bold)).tracking(1)
            }
            .foregroundStyle(Theme.glow)
            .frame(width: 44)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent.opacity(0.15)))

            VStack(alignment: .leading, spacing: 4) {
                Text(moment.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                if let place = moment.place, !place.isEmpty {
                    Label(place, systemImage: "mappin.and.ellipse").font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                if let note = moment.note, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.white.opacity(0.75))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(GlassRow(radius: 14).padding(.vertical, -3))
    }
}

// MARK: - Etkinlik düzenleme

/// Telefon takvimindeki etkinliği düzenle / ertele / sil
private struct EventEditor: View {
    @Environment(\.dismiss) private var dismiss
    let event: CalendarService.Event
    @State private var title: String
    @State private var start: Date
    @State private var end: Date
    @State private var location: String
    @State private var saving = false
    @State private var confirmDelete = false
    @State private var errorText: String?
    @State private var copied: CalendarService.Event?

    init(event: CalendarService.Event) {
        self.event = event
        _title = State(initialValue: event.title)
        _start = State(initialValue: event.start)
        _end = State(initialValue: event.end ?? event.start.addingTimeInterval(3600))
        _location = State(initialValue: event.location ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Başlık", text: $title)
                    TextField("Yer", text: $location)
                    DatePicker("Başlangıç", selection: $start)
                        .environment(\.locale, trLocale)
                        .onChange(of: start) { old, new in
                            // Süreyi koru
                            end = end.addingTimeInterval(new.timeIntervalSince(old))
                        }
                    if !event.allDay {
                        DatePicker("Bitiş", selection: $end, in: start...)
                            .environment(\.locale, trLocale)
                    }
                } footer: {
                    if let cal = event.calendarTitle {
                        Text("Takvim: \(cal)").font(.caption2).foregroundStyle(.white.opacity(0.45))
                    }
                }
                .glassRow()
                .disabled(!event.editable)

                if event.editable {
                    Section {
                        HStack(spacing: 8) {
                            shift("+1 saat", 3600)
                            shift("Yarın", 86400)
                            shift("+1 hafta", 7 * 86400)
                        }
                    } header: {
                        HUDHeader(text: "Ertele")
                    }
                    .glassRow()

                    Section {
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Label("Etkinliği sil", systemImage: "trash")
                        }
                    }
                    .glassRow()
                } else {
                    Section {
                        Text("Bu etkinlik salt okunur bir takvimde (ör. abone olunan ya da paylaşılan takvim), telefondan değiştirilemiyor.")
                            .font(.footnote).foregroundStyle(.white.opacity(0.6))
                        Button {
                            Task {
                                guard let id = event.id else { return }
                                if let newID = await CalendarService.shared.duplicate(id: id),
                                   let copy = CalendarService.shared.event(id: newID) {
                                    copied = copy
                                } else { errorText = "Kopyalanamadı. Takvim iznini kontrol et." }
                            }
                        } label: {
                            Label("Kendi takvimime kopyala ve düzenle", systemImage: "doc.on.doc")
                        }
                    }
                    .glassRow()
                }
                if let errorText {
                    Text(errorText).font(.footnote).foregroundStyle(.orange)
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Etkinlik")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
                if event.editable {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Kaydet") { save() }
                            .bold()
                            .disabled(saving || title.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .confirmationDialog("“\(event.title)” silinsin mi?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Etkinliği sil", role: .destructive) {
                    Task {
                        guard let id = event.id else { return }
                        if await CalendarService.shared.delete(id: id) { dismiss() } else { errorText = "Silinemedi. Takvim iznini kontrol et." }
                    }
                }
            } message: {
                Text("Telefon takviminden silinir.")
            }
        }
        .presentationBackground(.clear)
        .sheet(item: $copied, onDismiss: { dismiss() }) { c in EventEditor(event: c) }
    }

    private func shift(_ label: String, _ seconds: TimeInterval) -> some View {
        Button(label) {
            start = start.addingTimeInterval(seconds)
        }
        .buttonStyle(.borderless)
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(Theme.accent.opacity(0.2)))
    }

    private func save() {
        guard let id = event.id else { return }
        saving = true
        Task {
            let ok = await CalendarService.shared.update(id: id, title: title, start: start,
                                                          end: event.allDay ? nil : end, location: location)
            saving = false
            if ok { dismiss() } else { errorText = "Kaydedilemedi. Takvim iznini kontrol et." }
        }
    }
}

// MARK: - Ekleme sayfaları

private struct AddDay: Identifiable { let id = UUID(); let date: Date }

/// Takvime etkinlik ya da Jarvis'e hatırlatma ekler
private struct AddEventSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var kind = 0              // 0 etkinlik, 1 hatırlatma
    @State private var title = ""
    @State private var location = ""
    @State private var allDay = false
    @State private var start: Date
    @State private var end: Date
    @State private var calendarID: String = ""
    @State private var priority: Priority = .normal
    @State private var saving = false
    @State private var errorText: String?
    @State private var calendars: [CalendarService.CalendarInfo] = []

    init(day: Date) {
        let base = trCal.isDateInToday(day)
            ? trCal.date(bySetting: .minute, value: 0, of: Date().addingTimeInterval(3600)) ?? Date()
            : trCal.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
        _start = State(initialValue: base)
        _end = State(initialValue: base.addingTimeInterval(3600))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Tür", selection: $kind) {
                        Text("Takvim etkinliği").tag(0)
                        Text("Hatırlatma").tag(1)
                    }
                    .pickerStyle(.segmented)
                    TextField(kind == 0 ? "Başlık (ör. Dişçi randevusu)" : "Ne hatırlatayım?", text: $title)
                    if kind == 0 { TextField("Yer (isteğe bağlı)", text: $location) }
                }
                .glassRow()
                Section {
                    if kind == 0 { Toggle("Tüm gün", isOn: $allDay) }
                    DatePicker(kind == 0 ? "Başlangıç" : "Zaman", selection: $start,
                               displayedComponents: (kind == 0 && allDay) ? DatePickerComponents.date : DatePickerComponents([.date, .hourAndMinute]))
                        .environment(\.locale, trLocale)
                        .onChange(of: start) { old, new in end = end.addingTimeInterval(new.timeIntervalSince(old)) }
                    if kind == 0 && !allDay {
                        DatePicker("Bitiş", selection: $end, in: start...)
                            .environment(\.locale, trLocale)
                    }
                    if kind == 0 && calendars.count > 1 {
                        Picker("Takvim", selection: $calendarID) {
                            ForEach(calendars) { Text($0.title).tag($0.id) }
                        }
                    }
                    if kind == 1 {
                        Picker("Önem", selection: $priority) {
                            ForEach(Priority.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .glassRow()
                if let errorText {
                    Text(errorText).font(.footnote).foregroundStyle(.orange).listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(kind == 0 ? "Yeni etkinlik" : "Yeni hatırlatma")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ekle") { save() }
                        .bold()
                        .disabled(saving || title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .task {
                await CalendarService.shared.requestAccess()
                calendars = CalendarService.shared.writableCalendars()
                calendarID = CalendarService.shared.defaultCalendarID ?? calendars.first?.id ?? ""
            }
        }
        .presentationBackground(.clear)
    }

    private func save() {
        let t = title.trimmingCharacters(in: .whitespaces)
        if kind == 1 {
            store.upsert(TaskItem(title: t, due: start, priority: priority))
            Task { await Reminders.shared.requestPermission() }
            dismiss()
            return
        }
        saving = true
        Task {
            let s = allDay ? trCal.startOfDay(for: start) : start
            let e = allDay ? trCal.date(byAdding: .day, value: 1, to: s) : end
            let ok = await CalendarService.shared.add(title: t, start: s, end: e,
                                                       location: location.isEmpty ? nil : location,
                                                       important: false, allDay: allDay,
                                                       calendarID: calendarID.isEmpty ? nil : calendarID)
            saving = false
            if ok { dismiss() } else { errorText = "Eklenemedi. Ayarlar → Gizlilik → Takvimler'den Jarvis'e tam erişim ver." }
        }
    }
}

private struct AddSpecialSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var person = ""
    @State private var kind: SpecialKind = .birthday
    @State private var date = Date()
    @State private var knowsYear = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Tür", selection: $kind) {
                        ForEach(SpecialKind.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    TextField("Başlık (ör. Annemin doğum günü)", text: $title)
                    TextField("Kişi (isteğe bağlı)", text: $person)
                }
                .glassRow()
                Section {
                    DatePicker("Tarih", selection: $date, displayedComponents: .date)
                        .environment(\.locale, trLocale)
                    Toggle("Yılı biliyorum (yaşı hesaplansın)", isOn: $knowsYear)
                } footer: {
                    Text("Her yıl 1 hafta önce ve o gün hatırlatırım.")
                        .font(.caption2).foregroundStyle(.white.opacity(0.45))
                }
                .glassRow()
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Özel gün")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kaydet") {
                        let c = trCal.dateComponents([.year, .month, .day], from: date)
                        let t = title.trimmingCharacters(in: .whitespaces)
                        store.addSpecial(SpecialDay(title: t.isEmpty ? kind.label : t,
                                                    person: person.isEmpty ? nil : person,
                                                    month: c.month ?? 1, day: c.day ?? 1,
                                                    year: knowsYear ? c.year : nil, kind: kind))
                        Task { await Reminders.shared.requestPermission() }
                        dismiss()
                    }
                    .bold()
                }
            }
        }
        .presentationBackground(.clear)
    }
}

private struct AddMomentSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var date = Date()
    @State private var place = ""
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Ne oldu? (ör. Harbiye'de konuk sanatçı)", text: $title)
                    DatePicker("Tarih", selection: $date, displayedComponents: [.date, .hourAndMinute])
                        .environment(\.locale, trLocale)
                    TextField("Yer (isteğe bağlı)", text: $place)
                }
                .glassRow()
                Section {
                    TextField("Ayrıntılar, duygular, kimler vardı…", text: $note, axis: .vertical)
                        .lineLimit(3...8)
                }
                .glassRow()
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Anı")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kaydet") {
                        store.addMoment(Moment(title: title.trimmingCharacters(in: .whitespaces), date: date,
                                               place: place.isEmpty ? nil : place, note: note.isEmpty ? nil : note))
                        dismiss()
                    }
                    .bold()
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationBackground(.clear)
    }
}
