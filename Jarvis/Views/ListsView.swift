import SwiftUI

struct ListsView: View {
    @EnvironmentObject var store: Store
    @State private var section = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HUDTitle(text: "Listeler", subtitle: subtitle)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                HUDSegmented(items: [
                    ("Görevler", "checklist", store.openTasks.count),
                    ("Alışveriş", "cart.fill", store.shopping.count),
                    ("Aranacak", "phone.fill", store.calls.count)
                ], selection: $section)
                .padding(.horizontal, 16)

                Group {
                    switch section {
                    case 0: TasksList()
                    case 1: ShoppingList()
                    default: CallsList()
                    }
                }
                .transition(.opacity)
            }
            .background(Theme.background)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var subtitle: String {
        let critical = store.openTasks.filter { $0.priority == .critical }.count
        if critical > 0 { return "\(critical) kritik görev var" }
        if store.openTasks.isEmpty && store.shopping.isEmpty && store.calls.isEmpty { return "Her şey yolunda" }
        return "\(store.openTasks.count) görev · \(store.shopping.count) ürün · \(store.calls.count) arama"
    }
}

/// Listelerin üstündeki ekleme satırı
private struct AddRow: View {
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
    }

    private var canAdd: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty }

    private func add() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        onAdd(t)
        text = ""
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
    }
}

private struct TasksList: View {
    @EnvironmentObject var store: Store
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
                        .contentShape(Rectangle())
                        .onTapGesture { editing = task }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { store.delete(taskID: task.id) } label: { Label("Sil", systemImage: "trash") }
                        }
                        .swipeActions(edge: .leading) {
                            Button { store.complete(taskID: task.id) } label: { Label("Bitti", systemImage: "checkmark") }.tint(.green)
                        }
                        .glassRow()
                }
            } header: {
                if !store.openTasks.isEmpty { HUDHeader(text: "Açık görevler") }
            } footer: {
                if !store.openTasks.isEmpty {
                    Text("Sağa kaydır: bitti · Sola kaydır: sil · Dokun: düzenle")
                        .font(.caption2).foregroundStyle(.white.opacity(0.4))
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
            Button { store.complete(taskID: task.id) } label: {
                Image(systemName: "circle")
                    .font(.title3)
                    .foregroundStyle(Theme.color(for: task.priority))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title).foregroundStyle(.white)
                HStack(spacing: 8) {
                    if let due = task.due {
                        Label(DateText.friendly(due), systemImage: task.priority == .critical ? "alarm.fill" : "bell")
                            .foregroundStyle(due < Date() ? .red : .white.opacity(0.55))
                    }
                    if task.priority != .normal {
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
    }
}

private struct TaskEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State var task: TaskItem
    @State private var hasDue: Bool

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

private struct ShoppingList: View {
    @EnvironmentObject var store: Store

    var body: some View {
        HUDList {
            Section {
                AddRow(placeholder: "Ürün ekle", icon: "cart.badge.plus") { _ = store.addShopping([$0]) }
                    .glassRow()
            }
            Section {
                if store.shopping.isEmpty {
                    EmptyRow(icon: "cart", text: "Liste boş. \"Alınacaklara süt ekle\" diyebilirsin.")
                        .glassRow()
                }
                ForEach(store.shopping) { item in
                    HStack(spacing: 12) {
                        Button {
                            withAnimation { store.shopping.removeAll { $0.id == item.id } }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            Image(systemName: "circle").font(.title3).foregroundStyle(Theme.glow)
                        }
                        .buttonStyle(.plain)
                        Text(item.name).foregroundStyle(.white)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                    .glassRow()
                }
                .onDelete { store.shopping.remove(atOffsets: $0) }
            } header: {
                if !store.shopping.isEmpty { HUDHeader(text: "Alınacaklar") }
            } footer: {
                if !store.shopping.isEmpty {
                    Text("Aldığın ürüne dokun, listeden çıksın.")
                        .font(.caption2).foregroundStyle(.white.opacity(0.4))
                }
            }
            if !store.shopping.isEmpty {
                Section {
                    Button("Listeyi temizle", role: .destructive) { withAnimation { store.shopping.removeAll() } }
                        .buttonStyle(HUDButtonStyle(prominent: false, tint: .red))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
            }
        }
    }
}

private struct CallsList: View {
    @EnvironmentObject var store: Store
    @State private var notFound: String?

    var body: some View {
        HUDList {
            Section {
                AddRow(placeholder: "Kimi arayacaksın?", icon: "person.badge.plus") { store.calls.append(CallItem(person: $0)) }
                    .glassRow()
            }
            Section {
                if store.calls.isEmpty {
                    EmptyRow(icon: "phone", text: "Aranacak kimse yok.")
                        .glassRow()
                }
                ForEach(store.calls) { call in
                    HStack(spacing: 12) {
                        Text(String(call.person.prefix(1)).uppercased(with: Locale(identifier: "tr_TR")))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Theme.accent.opacity(0.25)))
                            .overlay(Circle().stroke(Theme.glow.opacity(0.5), lineWidth: 1))
                            .foregroundStyle(Theme.glow)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(call.person).foregroundStyle(.white)
                            if let r = call.reason, !r.isEmpty {
                                Text(r).font(.caption).foregroundStyle(.white.opacity(0.55))
                            }
                        }
                        Spacer()
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
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                    .swipeActions {
                        Button { store.calls.removeAll { $0.id == call.id } } label: { Label("Arandı", systemImage: "checkmark") }.tint(.green)
                    }
                    .glassRow()
                }
            } header: {
                if !store.calls.isEmpty { HUDHeader(text: "Aranacaklar") }
            }
        }
        .alert("Rehberde bulunamadı", isPresented: Binding(get: { notFound != nil }, set: { if !$0 { notFound = nil } })) {
            Button("Tamam", role: .cancel) {}
        } message: {
            Text("\(notFound ?? "") rehberde telefon numarasıyla bulunamadı ya da rehber izni kapalı.")
        }
    }
}
