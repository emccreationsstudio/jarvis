import SwiftUI

/// Listeler sekmesi: Görevler · Alışveriş · Aranacak + kullanıcının açtığı listeler (Eczane, Günlük ilaçlar…)
/// Dokun → işaretle (silinmez) · Sola kaydır → çöp kutusuna (30 gün geri alınabilir)
struct ListsView: View {
    @EnvironmentObject var store: Store
    @State private var selection = "tasks"
    @State private var creatingList = false
    @State private var showingTrash = false
    @State private var undo: TrashEntry?
    @State private var undoTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack(alignment: .top) {
                    HUDTitle(text: "Listeler", subtitle: subtitle)
                    Button { showingTrash = true } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "trash")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(Theme.glow.opacity(0.85))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                            if !store.trash.isEmpty {
                                Text("\(store.trash.count)")
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Capsule().fill(Theme.accent))
                                    .foregroundStyle(.white)
                                    .offset(x: -4, y: 6)
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Çöp kutusu")
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                ListChips(selection: $selection, onNew: { creatingList = true })

                Group {
                    switch selection {
                    case "tasks": TasksList(onTrash: showUndo)
                    case "shopping": ShoppingList(onTrash: showUndo)
                    case "calls": CallsList(onTrash: showUndo)
                    default:
                        if let list = store.lists.first(where: { $0.id == selection }) {
                            CustomListView(listID: list.id, onTrash: showUndo) { selection = "tasks" }
                        } else {
                            TasksList(onTrash: showUndo)
                        }
                    }
                }
                .transition(.opacity)
            }
            .background(Theme.background)
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .bottom) { undoBanner }
            .sheet(isPresented: $creatingList) {
                NewListSheet { id in selection = id }
            }
            .sheet(isPresented: $showingTrash) { TrashView() }
            .onAppear { store.housekeeping() }
            // Jarvis yeni bir liste açtıysa ya da liste silindiyse seçimi düzelt
            .onChange(of: store.lists.map(\.id)) { _, ids in
                if !["tasks", "shopping", "calls"].contains(selection) && !ids.contains(selection) { selection = "tasks" }
            }
        }
    }

    private var subtitle: String {
        let critical = store.openTasks.filter { $0.priority == .critical }.count
        if critical > 0 { return "\(critical) kritik görev var" }
        let shop = store.openShopping.count, calls = store.openCalls.count
        if store.openTasks.isEmpty && shop == 0 && calls == 0 { return "Her şey yolunda" }
        return "\(store.openTasks.count) görev · \(shop) ürün · \(calls) arama"
    }

    /// Silindikten sonra 5 sn "Geri al" şeridi
    private func showUndo() {
        undoTask?.cancel()
        withAnimation(.spring(response: 0.3)) { undo = store.trash.first }
        undoTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { undo = nil }
        }
    }

    @ViewBuilder private var undoBanner: some View {
        if let entry = undo {
            HStack(spacing: 12) {
                Image(systemName: "trash").foregroundStyle(.white.opacity(0.7))
                Text("“\(entry.title)” silindi").lineLimit(1).foregroundStyle(.white)
                Spacer(minLength: 8)
                Button("Geri al") {
                    store.restore(entry)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    withAnimation { undo = nil }
                }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.glow)
                .buttonStyle(.borderless)
            }
            .font(.subheadline)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Theme.cardStroke, lineWidth: 1))
            .padding(.horizontal, 16)
            .padding(.bottom, 12 + TalkView.floatingTabBarClearance)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - Liste seçici (kaydırılabilir)

private struct ListChips: View {
    @EnvironmentObject var store: Store
    @Binding var selection: String
    let onNew: () -> Void

    private struct Chip: Identifiable {
        let id: String
        let title: String
        let icon: String
        let count: Int
    }

    private var chips: [Chip] {
        [
            Chip(id: "tasks", title: "Görevler", icon: "checklist", count: store.openTasks.count),
            Chip(id: "shopping", title: "Alışveriş", icon: "cart.fill", count: store.openShopping.count),
            Chip(id: "calls", title: "Aranacak", icon: "phone.fill", count: store.openCalls.count)
        ] + store.lists.map { Chip(id: $0.id, title: $0.name, icon: $0.icon, count: $0.openCount) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(chips) { chip in
                        let selected = selection == chip.id
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selection = chip.id }
                            UISelectionFeedbackGenerator().selectionChanged()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: chip.icon).font(.system(size: 12, weight: .semibold))
                                Text(chip.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                if chip.count > 0 {
                                    Text("\(chip.count)")
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(Capsule().fill(selected ? Color.white.opacity(0.25) : Theme.glow.opacity(0.2)))
                                }
                            }
                            .foregroundStyle(selected ? .white : .white.opacity(0.65))
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background {
                                if selected {
                                    Capsule()
                                        .fill(LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                                        .shadow(color: Theme.glow.opacity(0.6), radius: 8)
                                } else {
                                    Capsule().fill(Color.white.opacity(0.06))
                                }
                            }
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.borderless)
                        .id(chip.id)
                    }
                    Button(action: onNew) {
                        Label("Yeni liste", systemImage: "plus")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.glow)
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(Capsule().stroke(Theme.glow.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.borderless)
                }
                .padding(4)
            }
            .scrollIndicators(.hidden)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Theme.cardStroke, lineWidth: 1))
            .padding(.horizontal, 16)
            .onChange(of: selection) { _, id in withAnimation { proxy.scrollTo(id, anchor: .center) } }
        }
    }
}

// MARK: - Ortak parçalar

/// Listelerin üstündeki ekleme satırı. "+" her zaman çalışır: alan boşsa yazma alanını açar.
struct AddRow: View {
    let placeholder: String
    let icon: String
    let onAdd: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.glow.opacity(0.8))
            TextField("", text: $text, prompt: Text(placeholder).foregroundColor(.white.opacity(0.4)))
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(add)
                .foregroundStyle(.white)
            Button(action: add) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(canAdd ? Theme.accent : Color.white.opacity(0.14)))
                    .shadow(color: canAdd ? Theme.glow.opacity(0.6) : .clear, radius: 6)
                    .frame(width: 44, height: 44)      // geniş dokunma alanı
                    .contentShape(Rectangle())
            }
            // .borderless: liste satırında yalnızca düğmenin kendisi dokunuşu alır
            .buttonStyle(.borderless)
            .accessibilityLabel("Ekle")
        }
        .padding(.vertical, -4)
    }

    private var canAdd: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func add() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else {
            focused = true            // boşken "+" → yazmaya başla
            return
        }
        onAdd(t)
        text = ""
        focused = true                // art arda ekleyebilmek için klavye açık kalsın
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

/// Boş liste mesajı
private struct EmptyRow: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(Theme.glow.opacity(0.5))
            Text(text).font(.subheadline).foregroundStyle(.white.opacity(0.55))
        }
        .padding(.vertical, 8)
    }
}

/// Tüm listelerde ortak görünüm
private struct HUDList<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        List { content }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .listRowSpacing(6)
            .contentMargins(.top, 4, for: .scrollContent)
            .contentMargins(.bottom, 80, for: .scrollContent)
    }
}

/// İşaretlenebilir satır: dokun → işaretle / işareti kaldır
private struct CheckRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    let done: Bool
    var color: Color = Theme.glow
    let onToggle: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(done ? Color.green : color)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .strikethrough(done, color: .white.opacity(0.5))
                    .foregroundStyle(.white.opacity(done ? 0.45 : 1))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.white.opacity(done ? 0.3 : 0.55))
                }
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { onToggle() }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
}

extension CheckRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, done: Bool, color: Color = Theme.glow, onToggle: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, done: done, color: color, onToggle: onToggle, trailing: { EmptyView() })
    }
}

private struct HintFooter: View {
    let text: String
    var body: some View {
        Text(text).font(.caption2).foregroundStyle(.white.opacity(0.4))
    }
}

// MARK: - Görevler

private struct TasksList: View {
    @EnvironmentObject var store: Store
    let onTrash: () -> Void
    @State private var editing: TaskItem?

    var body: some View {
        HUDList {
            Section {
                AddRow(placeholder: "Yeni görev", icon: "plus.circle") { store.upsert(TaskItem(title: $0)) }
                    .glassRow()
            }
            Section {
                if store.openTasks.isEmpty {
                    EmptyRow(icon: "checkmark.seal", text: "Açık görev yok. Jarvis'e söyleyebilir ya da yukarıdan ekleyebilirsin.")
                        .glassRow()
                }
                ForEach(store.openTasks) { task in
                    TaskRow(task: task)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { store.delete(taskID: task.id); onTrash() } label: { Label("Sil", systemImage: "trash") }
                        }
                        .swipeActions(edge: .leading) {
                            Button { editing = task } label: { Label("Düzenle", systemImage: "pencil") }.tint(Theme.accent)
                        }
                        .contextMenu {
                            Button { editing = task } label: { Label("Düzenle", systemImage: "pencil") }
                            Button(role: .destructive) { store.delete(taskID: task.id); onTrash() } label: { Label("Sil", systemImage: "trash") }
                        }
                        .glassRow()
                }
            } header: {
                if !store.openTasks.isEmpty { HUDHeader(text: "Açık görevler") }
            } footer: {
                if !store.openTasks.isEmpty {
                    HintFooter(text: "Dokun: bitti · Sağa kaydır: düzenle · Sola kaydır: sil (çöp kutusundan geri alınır)")
                }
            }
            if !store.doneToday.isEmpty {
                Section {
                    ForEach(store.doneToday) { task in
                        TaskRow(task: task)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { store.delete(taskID: task.id); onTrash() } label: { Label("Sil", systemImage: "trash") }
                            }
                            .glassRow()
                    }
                } header: {
                    HUDHeader(text: "Bugün tamamlananlar")
                } footer: {
                    HintFooter(text: "Yanlışlıkla işaretlediysen dokun, geri açılır.")
                }
            }
        }
        .sheet(item: $editing) { task in
            TaskEditor(task: task)
        }
    }
}

private struct TaskRow: View {
    @EnvironmentObject var store: Store
    let task: TaskItem

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Önem rengi: ışıklı şerit
            Capsule()
                .fill(Theme.color(for: task.priority))
                .frame(width: 3)
                .shadow(color: Theme.color(for: task.priority).opacity(0.8), radius: 4)
                .padding(.vertical, 2)
                .opacity(task.done ? 0.3 : 1)
            Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(task.done ? Color.green : Theme.color(for: task.priority))
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .strikethrough(task.done, color: .white.opacity(0.5))
                    .foregroundStyle(.white.opacity(task.done ? 0.45 : 1))
                HStack(spacing: 8) {
                    if let due = task.due {
                        Label(DateText.friendly(due), systemImage: task.priority == .critical ? "alarm.fill" : "bell")
                            .foregroundStyle(!task.done && due < Date() ? .red : .white.opacity(0.55))
                    }
                    if task.priority != .normal && !task.done {
                        Text(task.priority.label)
                            .padding(.horizontal, 7).padding(.vertical, 1)
                            .background(Theme.color(for: task.priority).opacity(0.2), in: Capsule())
                            .overlay(Capsule().stroke(Theme.color(for: task.priority).opacity(0.5), lineWidth: 0.5))
                            .foregroundStyle(Theme.color(for: task.priority))
                    }
                }
                .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { store.toggle(taskID: task.id) }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
}

/// Görev düzenleme sayfası (Takvim'den de açılır)
struct TaskEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State var task: TaskItem
    @State private var hasDue: Bool

    private struct Shortcut { let label: String; let seconds: TimeInterval }
    private static let shortcuts = [Shortcut(label: "+1 sa", seconds: 3600),
                                    Shortcut(label: "Yarın", seconds: 86400),
                                    Shortcut(label: "+1 hafta", seconds: 7 * 86400)]

    init(task: TaskItem) {
        _task = State(initialValue: task)
        _hasDue = State(initialValue: task.due != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Başlık", text: $task.title)
                    Toggle("Hatırlat", isOn: $hasDue)
                    if hasDue {
                        DatePicker("Zaman", selection: Binding(get: { task.due ?? Date().addingTimeInterval(3600) }, set: { task.due = $0 }))
                            .environment(\.locale, Locale(identifier: "tr_TR"))
                        HStack(spacing: 8) {
                            ForEach(Self.shortcuts, id: \.label) { item in
                                Button(item.label) {
                                    task.due = (task.due ?? Date()).addingTimeInterval(item.seconds)
                                }
                                .buttonStyle(.borderless)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Capsule().fill(Theme.accent.opacity(0.2)))
                            }
                        }
                    }
                }
                .glassRow()
                Section {
                    Picker("Önem", selection: $task.priority) {
                        ForEach(Priority.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    HUDHeader(text: "Önem")
                } footer: {
                    Text("Kritik: alarm gibi çalar. Yüksek: 5 ve 10 dakika sonra tekrar hatırlatır. Düşük: sessiz bildirim.")
                        .font(.footnote).foregroundStyle(.white.opacity(0.45))
                }
                .glassRow()
                if store.task(task.id) != nil {
                    Section {
                        Button(role: .destructive) {
                            store.delete(taskID: task.id)
                            dismiss()
                        } label: {
                            Label("Görevi sil", systemImage: "trash")
                        }
                    } footer: {
                        Text("Silinen görev 30 gün çöp kutusunda kalır.")
                            .font(.footnote).foregroundStyle(.white.opacity(0.45))
                    }
                    .glassRow()
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Görev")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kaydet") {
                        if !hasDue { task.due = nil } else if task.due == nil { task.due = Date().addingTimeInterval(3600) }
                        store.upsert(task)
                        Task { await Reminders.shared.requestPermission() }
                        dismiss()
                    }
                    .bold()
                    .disabled(task.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationBackground(.clear)
    }
}

// MARK: - Alışveriş

private struct ShoppingList: View {
    @EnvironmentObject var store: Store
    let onTrash: () -> Void

    private var done: [ShoppingItem] { store.shopping.filter(\.done) }

    var body: some View {
        HUDList {
            Section {
                AddRow(placeholder: "Ürün ekle", icon: "cart.badge.plus") { _ = store.addShopping([$0]) }
                    .glassRow()
            }
            Section {
                if store.openShopping.isEmpty {
                    EmptyRow(icon: "cart", text: done.isEmpty ? "Liste boş. \"Alınacaklara süt ekle\" diyebilirsin." : "Hepsi alındı.")
                        .glassRow()
                }
                ForEach(store.openShopping) { item in
                    CheckRow(title: item.name, done: false) { store.toggleShopping(id: item.id) }
                        .swipeActions { trashButton(item) }
                        .glassRow()
                }
            } header: {
                if !store.openShopping.isEmpty { HUDHeader(text: "Alınacaklar") }
            } footer: {
                if !store.openShopping.isEmpty {
                    HintFooter(text: "Aldığın ürüne dokun, işaretlensin · Sola kaydır: sil")
                }
            }
            if !done.isEmpty {
                Section {
                    ForEach(done) { item in
                        CheckRow(title: item.name, done: true) { store.toggleShopping(id: item.id) }
                            .swipeActions { trashButton(item) }
                            .glassRow()
                    }
                    Button {
                        withAnimation { store.clearDoneShopping() }
                        onTrash()
                    } label: {
                        Label("Alınanları temizle", systemImage: "trash")
                    }
                    .buttonStyle(HUDButtonStyle(prominent: false, tint: .red))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                } header: {
                    HUDHeader(text: "Alındı")
                }
            }
        }
    }

    private func trashButton(_ item: ShoppingItem) -> some View {
        Button(role: .destructive) { store.trashShopping(id: item.id); onTrash() } label: { Label("Sil", systemImage: "trash") }
    }
}

// MARK: - Aranacaklar

private struct CallsList: View {
    @EnvironmentObject var store: Store
    let onTrash: () -> Void
    @State private var notFound: String?

    private var done: [CallItem] { store.calls.filter(\.done) }

    var body: some View {
        HUDList {
            Section {
                AddRow(placeholder: "Kimi arayacaksın?", icon: "person.badge.plus") { store.addCall(person: $0, reason: nil) }
                    .glassRow()
            }
            Section {
                if store.openCalls.isEmpty {
                    EmptyRow(icon: "phone", text: "Aranacak kimse yok.")
                        .glassRow()
                }
                ForEach(store.openCalls) { call in row(call) }
            } header: {
                if !store.openCalls.isEmpty { HUDHeader(text: "Aranacaklar") }
            } footer: {
                if !store.openCalls.isEmpty {
                    HintFooter(text: "Dokun: arandı · Yeşil düğme: hemen ara · Sola kaydır: sil")
                }
            }
            if !done.isEmpty {
                Section {
                    ForEach(done) { call in row(call) }
                } header: {
                    HUDHeader(text: "Arandı")
                }
            }
        }
        .alert("Rehberde bulunamadı", isPresented: Binding(get: { notFound != nil }, set: { if !$0 { notFound = nil } })) {
            Button("Tamam", role: .cancel) {}
        } message: {
            Text("\(notFound ?? "") rehberde telefon numarasıyla bulunamadı ya da rehber izni kapalı.")
        }
    }

    private func row(_ call: CallItem) -> some View {
        CheckRow(title: call.person, subtitle: call.reason, done: call.done, color: .green) {
            store.toggleCall(id: call.id)
        } trailing: {
            Button {
                Task {
                    let ok = await ContactsService.call(call.person)
                    if !ok { notFound = call.person }
                }
            } label: {
                Image(systemName: "phone.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.green.opacity(0.22)))
                    .overlay(Circle().stroke(Color.green.opacity(0.6), lineWidth: 1))
                    .shadow(color: .green.opacity(0.5), radius: 6)
                    .foregroundStyle(.green)
            }
            .buttonStyle(.borderless)
            .opacity(call.done ? 0.5 : 1)
        }
        .swipeActions {
            Button(role: .destructive) { store.trashCall(id: call.id); onTrash() } label: { Label("Sil", systemImage: "trash") }
        }
        .glassRow()
    }
}

// MARK: - Kullanıcının listeleri

private struct CustomListView: View {
    @EnvironmentObject var store: Store
    let listID: String
    let onTrash: () -> Void
    let onDeleted: () -> Void
    @State private var renaming = false
    @State private var confirmDelete = false

    private var list: CustomList? { store.lists.first { $0.id == listID } }

    var body: some View {
        if let list {
            let open = list.items.filter { !$0.done }
            let done = list.items.filter(\.done)
            HUDList {
                Section {
                    AddRow(placeholder: "\(list.name) listesine ekle", icon: list.icon) {
                        store.addListItems([$0], to: list.name)
                    }
                    .glassRow()
                } header: {
                    HStack {
                        if list.daily {
                            Label("Günlük · her sabah sıfırlanır", systemImage: "sunrise.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.glow.opacity(0.85))
                        }
                        Spacer()
                        Menu {
                            Button { renaming = true } label: { Label("Adını / türünü değiştir", systemImage: "pencil") }
                            if !done.isEmpty {
                                Button { store.clearDoneItems(listID: list.id); onTrash() } label: { Label("İşaretlileri temizle", systemImage: "checkmark.circle") }
                            }
                            Button(role: .destructive) { confirmDelete = true } label: { Label("Listeyi sil", systemImage: "trash") }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.title3)
                                .foregroundStyle(Theme.glow.opacity(0.85))
                                .frame(width: 44, height: 32)
                                .contentShape(Rectangle())
                        }
                    }
                    .textCase(nil)
                }
                Section {
                    if list.items.isEmpty {
                        EmptyRow(icon: list.icon, text: "Liste boş. Yukarıdan ekleyebilir ya da \"\(list.name) listesine … ekle\" diyebilirsin.")
                            .glassRow()
                    }
                    ForEach(open) { item in itemRow(item, list: list) }
                } footer: {
                    if !open.isEmpty {
                        HintFooter(text: list.daily ? "Dokun: bugün tamam · Yarın sabah yeniden açılır" : "Dokun: işaretle · Sola kaydır: sil")
                    }
                }
                if !done.isEmpty {
                    Section {
                        ForEach(done) { item in itemRow(item, list: list) }
                    } header: {
                        HUDHeader(text: list.daily ? "Bugün tamam" : "İşaretliler")
                    }
                }
            }
            .sheet(isPresented: $renaming) { NewListSheet(editing: list) { _ in } }
            .confirmationDialog("“\(list.name)” silinsin mi?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Listeyi sil", role: .destructive) {
                    store.trashList(id: list.id)
                    onTrash()
                    onDeleted()
                }
            } message: {
                Text("Liste 30 gün çöp kutusunda kalır, oradan geri alabilirsin.")
            }
        }
    }

    private func itemRow(_ item: ListItem, list: CustomList) -> some View {
        CheckRow(title: item.text, done: item.done) {
            store.toggleListItem(listID: list.id, itemID: item.id)
        }
        .swipeActions {
            Button(role: .destructive) { store.trashListItem(listID: list.id, itemID: item.id); onTrash() } label: { Label("Sil", systemImage: "trash") }
        }
        .glassRow()
    }
}

/// Yeni liste aç / listeyi düzenle
private struct NewListSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    var editing: CustomList? = nil
    let onDone: (String) -> Void
    @State private var name = ""
    @State private var daily = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Liste adı (ör. Eczane)", text: $name)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(save)
                    Toggle(isOn: $daily) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Günlük liste")
                            Text("İşaretler her sabah kalkar. Günlük ilaçlar, vitaminler, rutinler için.")
                                .font(.caption).foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
                .glassRow()
                if editing == nil {
                    Section {
                        ForEach(["Eczane", "Günlük ilaçlar", "Hediye fikirleri", "Stüdyo"], id: \.self) { suggestion in
                            Button {
                                name = suggestion
                                daily = suggestion == "Günlük ilaçlar"
                            } label: {
                                Label(suggestion, systemImage: CustomList.icon(for: suggestion))
                            }
                        }
                    } header: {
                        HUDHeader(text: "Öneriler")
                    } footer: {
                        Text("Jarvis'e \"Eczane diye bir liste aç\" ya da \"Günlük ilaç listeme D vitamini ekle\" de diyebilirsin.")
                            .font(.caption2).foregroundStyle(.white.opacity(0.45))
                    }
                    .glassRow()
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(editing == nil ? "Yeni liste" : "Listeyi düzenle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Oluştur" : "Kaydet", action: save)
                        .bold()
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let editing { name = editing.name; daily = editing.daily }
                focused = editing == nil
            }
        }
        .presentationBackground(.clear)
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        if let editing {
            store.renameList(id: editing.id, to: n, daily: daily)
            onDone(editing.id)
        } else {
            let l = store.createList(name: n, daily: daily)
            onDone(l.id)
        }
        dismiss()
    }
}

// MARK: - Çöp kutusu

struct TrashView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var confirmEmpty = false

    var body: some View {
        NavigationStack {
            List {
                if store.trash.isEmpty {
                    EmptyRow(icon: "trash", text: "Çöp kutusu boş.")
                        .glassRow()
                }
                Section {
                    ForEach(store.trash) { entry in
                        HStack(spacing: 12) {
                            Image(systemName: entry.icon)
                                .foregroundStyle(Theme.glow.opacity(0.8))
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title).foregroundStyle(.white).lineLimit(2)
                                Text("\(entry.source) · \(DateText.friendly(entry.deletedAt))")
                                    .font(.caption).foregroundStyle(.white.opacity(0.5))
                            }
                            Spacer(minLength: 0)
                            Button {
                                withAnimation { store.restore(entry) }
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                            } label: {
                                Label("Geri al", systemImage: "arrow.uturn.backward")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10).padding(.vertical, 7)
                                    .background(Capsule().fill(Theme.accent.opacity(0.25)))
                                    .overlay(Capsule().stroke(Theme.glow.opacity(0.5), lineWidth: 1))
                                    .foregroundStyle(Theme.glow)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                        .swipeActions {
                            Button(role: .destructive) { store.purge(entry) } label: { Label("Kalıcı sil", systemImage: "xmark.bin") }
                        }
                        .glassRow()
                    }
                } footer: {
                    if !store.trash.isEmpty {
                        HintFooter(text: "Silinenler 30 gün burada kalır. Sola kaydır: kalıcı olarak sil.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .listRowSpacing(6)
            .background(Theme.background)
            .navigationTitle("Çöp kutusu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Kapat") { dismiss() } }
                if !store.trash.isEmpty {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Boşalt", role: .destructive) { confirmEmpty = true }
                    }
                }
            }
            .confirmationDialog("Çöp kutusu boşaltılsın mı?", isPresented: $confirmEmpty, titleVisibility: .visible) {
                Button("Hepsini kalıcı olarak sil", role: .destructive) { store.emptyTrash() }
            }
        }
        .presentationBackground(.clear)
    }
}
