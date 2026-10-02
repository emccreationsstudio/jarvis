import SwiftUI

struct ListsView: View {
    @EnvironmentObject var store: Store
    @State private var section = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Liste", selection: $section) {
                    Text("Görevler (\(store.openTasks.count))").tag(0)
                    Text("Alışveriş (\(store.shopping.count))").tag(1)
                    Text("Aranacak (\(store.calls.count))").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                switch section {
                case 0: TasksList()
                case 1: ShoppingList()
                default: CallsList()
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Listeler")
        }
    }
}

private struct AddRow: View {
    let placeholder: String
    let onAdd: (String) -> Void
    @State private var text = ""

    var body: some View {
        HStack {
            TextField(placeholder, text: $text)
                .submitLabel(.done)
                .onSubmit(add)
            Button(action: add) { Image(systemName: "plus.circle.fill").font(.title2) }
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func add() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        onAdd(t)
        text = ""
    }
}

private struct TasksList: View {
    @EnvironmentObject var store: Store
    @State private var editing: TaskItem?

    var body: some View {
        List {
            Section {
                AddRow(placeholder: "Yeni görev") { store.upsert(TaskItem(title: $0)) }
            }
            Section {
                if store.openTasks.isEmpty {
                    Text("Açık görev yok. Jarvis'e söyleyebilir ya da yukarıdan ekleyebilirsin.")
                        .foregroundStyle(.secondary).font(.subheadline)
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
                }
            }
        }
        .scrollContentBackground(.hidden)
        .sheet(item: $editing) { task in
            TaskEditor(task: task)
        }
    }
}

private struct TaskRow: View {
    @EnvironmentObject var store: Store
    let task: TaskItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { store.complete(taskID: task.id) } label: {
                Image(systemName: "circle").font(.title3).foregroundStyle(Theme.color(for: task.priority))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                HStack(spacing: 8) {
                    if let due = task.due {
                        Label(DateText.friendly(due), systemImage: task.priority == .critical ? "alarm.fill" : "bell")
                            .foregroundStyle(due < Date() ? .red : .secondary)
                    }
                    if task.priority != .normal {
                        Text(task.priority.label)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Theme.color(for: task.priority).opacity(0.2), in: Capsule())
                            .foregroundStyle(Theme.color(for: task.priority))
                    }
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 2)
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
                TextField("Başlık", text: $task.title)
                Toggle("Hatırlat", isOn: $hasDue)
                if hasDue {
                    DatePicker("Zaman", selection: Binding(get: { task.due ?? Date().addingTimeInterval(3600) }, set: { task.due = $0 }))
                        .environment(\.locale, Locale(identifier: "tr_TR"))
                }
                Picker("Önem", selection: $task.priority) {
                    ForEach(Priority.allCases) { Text($0.label).tag($0) }
                }
                Section {
                    Text("Kritik: alarm gibi çalar. Yüksek: 5 ve 10 dakika sonra tekrar hatırlatır. Düşük: sessiz bildirim.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
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
                    .disabled(task.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

private struct ShoppingList: View {
    @EnvironmentObject var store: Store

    var body: some View {
        List {
            Section {
                AddRow(placeholder: "Ürün ekle") { _ = store.addShopping([$0]) }
            }
            Section {
                if store.shopping.isEmpty {
                    Text("Liste boş. \"Alınacaklara süt ekle\" diyebilirsin.").foregroundStyle(.secondary).font(.subheadline)
                }
                ForEach(store.shopping) { item in
                    HStack {
                        Button { store.shopping.removeAll { $0.id == item.id } } label: {
                            Image(systemName: "circle").font(.title3)
                        }
                        .buttonStyle(.plain)
                        Text(item.name)
                    }
                }
                .onDelete { store.shopping.remove(atOffsets: $0) }
            } footer: {
                if !store.shopping.isEmpty {
                    Text("Aldığın ürüne dokun, listeden çıksın.")
                }
            }
            if !store.shopping.isEmpty {
                Section {
                    Button("Listeyi temizle", role: .destructive) { store.shopping.removeAll() }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }
}

private struct CallsList: View {
    @EnvironmentObject var store: Store
    @State private var notFound: String?

    var body: some View {
        List {
            Section {
                AddRow(placeholder: "Kimi arayacaksın?") { store.calls.append(CallItem(person: $0)) }
            }
            Section {
                if store.calls.isEmpty {
                    Text("Aranacak kimse yok.").foregroundStyle(.secondary).font(.subheadline)
                }
                ForEach(store.calls) { call in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(call.person)
                            if let r = call.reason, !r.isEmpty {
                                Text(r).font(.caption).foregroundStyle(.secondary)
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
                                .padding(10)
                                .background(Color.green.opacity(0.2), in: Circle())
                                .foregroundStyle(.green)
                        }
                        .buttonStyle(.plain)
                    }
                    .swipeActions {
                        Button { store.calls.removeAll { $0.id == call.id } } label: { Label("Arandı", systemImage: "checkmark") }.tint(.green)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .alert("Rehberde bulunamadı", isPresented: Binding(get: { notFound != nil }, set: { if !$0 { notFound = nil } })) {
            Button("Tamam", role: .cancel) {}
        } message: {
            Text("\(notFound ?? "") rehberde telefon numarasıyla bulunamadı ya da rehber izni kapalı.")
        }
    }
}
