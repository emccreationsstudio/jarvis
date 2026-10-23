import Foundation

/// Cihazlar arası eşitleme (telefon ↔ bilgisayar).
///
/// 1.2.5: "ekleyen kazanır". Eskiden en son değiştiren cihazın TÜM verisi öbürünün üstüne yazılıyordu;
/// telefonda eksik veri varken eşitleme olunca bilgisayarda girilen görevler siliniyordu.
/// Artık iki taraf kayıt kayıt birleştirilir:
///  • Bir tarafta olup öbüründe olmayan kayıt KORUNUR (eksiklik silme sayılmaz).
///  • İki tarafta da olan kayıtta, sadece bir taraf değiştirdiyse o değişiklik kazanır.
///  • Bir kayıt yalnızca açıkça silindiyse (çöp kutusu ya da bu cihazda silindi) iki taraftan da silinir.
///    Silinenler "deleted", çöpten geri alınanlar "revived" olarak kayda eklenir (bilgisayar da aynısını yapar).
@MainActor
final class SyncService {
    static let shared = SyncService()

    typealias JSON = [String: Any]

    private var pushTask: Task<Void, Never>?
    private var running = false
    private var again = false
    /// Ayarlar'da gösterilen son durum
    private(set) var lastStatus: String = "Henüz eşitlenmedi"

    private var tomb: [String: String] = [:]
    private var revived: [String: String] = [:]

    private var settings: AppSettings { AppSettings.shared }

    /// Telefonun sahip olduğu ve birleştirilen bölümler
    private static let keys: [(String, String?)] = [("tasks", nil), ("shopping", nil), ("calls", nil),
                                                    ("lists", "items"), ("memory", nil)]
    private static let fTask = ["title", "due", "priority", "done", "doneAt"]
    private static let fShop = ["name", "done"]
    private static let fCall = ["person", "reason", "done"]
    private static let fMem = ["text"]
    private static let fList = ["name", "daily"]
    private static let fItem = ["text", "done"]
    private static let dateKeys: Set<String> = ["due", "doneAt", "createdAt"]

    private let baseURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("jarvis-sync-base.json")
    }()

    private func endpoint() -> URL? {
        let base = settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: base + "/sync")
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]   // 2026-10-03T10:00:00.123Z
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()                    // 2026-10-03T10:00:00Z

    private static func parse(_ s: String) -> Date? {
        isoFrac.date(from: s) ?? isoPlain.date(from: s)
    }

    // MARK: - Dışarıya açık

    /// Sunucuyla birleştir (eski adı korunuyor)
    @discardableResult
    func pull() async -> String { await sync() }

    /// Yerel değişiklikten 2 sn sonra birleştir (art arda değişiklikleri birleştirir)
    func schedulePush(immediately: Bool = false) {
        guard settings.syncEnabled, settings.isConfigured else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            guard !Task.isCancelled else { return }
            _ = await self?.sync()
        }
    }

    // MARK: - Birleştirme

    @discardableResult
    func sync() async -> String {
        guard settings.syncEnabled, settings.isConfigured, let url = endpoint() else { return lastStatus }
        if running { again = true; return lastStatus }
        running = true
        defer {
            running = false
            if again { again = false; schedulePush(immediately: true) }
        }

        // 1) Sunucudaki kayıt
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        let env: JSON
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 501 { lastStatus = "Sunucuda eşitleme kurulmamış (JARVIS_KV)."; return lastStatus }
            guard status == 200 else { lastStatus = "Eşitleme hatası (\(status))"; return lastStatus }
            env = ((try? JSONSerialization.jsonObject(with: data)) as? JSON) ?? [:]
        } catch {
            lastStatus = "Sunucuya ulaşılamadı"
            return lastStatus
        }
        let remoteStamp = env["updatedAt"] as? String
        var remote = (env["data"] as? JSON) ?? [:]
        if remoteStamp == nil { remote = [:] }

        // 2) Bu cihazdaki veri
        let store = Store.shared
        guard let ld = try? Store.makeEncoder().encode(store.snapshot),
              let local = (try? JSONSerialization.jsonObject(with: ld)) as? JSON else {
            lastStatus = "Yerel veri okunamadı"
            return lastStatus
        }
        let base = loadBase()

        // 3) Silinme / geri alınma işaretleri
        buildMarks(base: base, local: local, remote: remote)

        // 4) Birleştir
        var merged = remote                                   // bilgisayara özgü alanlar (bilgi bankası…) korunur
        merged["tasks"] = merge(base["tasks"], local["tasks"], remote["tasks"], Self.fTask, nested: nil)
        merged["shopping"] = merge(base["shopping"], local["shopping"], remote["shopping"], Self.fShop, nested: nil)
        merged["calls"] = merge(base["calls"], local["calls"], remote["calls"], Self.fCall, nested: nil)
        merged["lists"] = merge(base["lists"], local["lists"], remote["lists"], Self.fList,
                                nested: ("items", Self.fItem))
        merged["memory"] = merge(base["memory"], local["memory"], remote["memory"], Self.fMem, nested: nil)
        // Telefona ait bölümler: sohbet ve çöp kutusu buradaki; özel günler/anlar ikisinin birleşimi
        merged["messages"] = local["messages"] ?? []
        merged["trash"] = local["trash"] ?? []
        merged["specials"] = union(local["specials"], remote["specials"])
        merged["moments"] = union(local["moments"], remote["moments"])
        merged["deleted"] = tomb
        merged["revived"] = revived

        // 5) Değişen bir şey varsa bu cihaza uygula
        var what: [String] = []
        if !same(merged, local) || !same(merged["specials"], local["specials"], Self.fMem)
            || !same(merged["moments"], local["moments"], Self.fMem) {
            var forDecode = merged
            forDecode.removeValue(forKey: "updatedAt")
            if let data = try? JSONSerialization.data(withJSONObject: forDecode),
               let snap = try? Store.makeDecoder().decode(Store.Snapshot.self, from: data) {
                store.applyRemote(snap, updatedAt: Date())
                what.append("bilgisayardan alındı")
            } else {
                lastStatus = "Bilgisayardaki veri okunamadı"
                return lastStatus
            }
        }

        // 6) Sunucudakinden farklıysa gönder
        let remoteDeleted = remote["deleted"] as? [String: String] ?? [:]
        let remoteRevived = remote["revived"] as? [String: String] ?? [:]
        let needPush = remoteStamp == nil || !same(merged, remote)
            || remoteDeleted != tomb || remoteRevived != revived
            || !same(merged["specials"], remote["specials"], Self.fMem)
            || !same(merged["moments"], remote["moments"], Self.fMem)
        if needPush {
            var stampDate = Date()
            if let rs = remoteStamp, let rd = Self.parse(rs), rd >= stampDate {
                stampDate = rd.addingTimeInterval(0.005)      // saat farkı olsa da yenisi bizimki olsun
            }
            let stamp = Self.isoFrac.string(from: stampDate)
            merged["updatedAt"] = stamp
            let payload: JSON = ["updatedAt": stamp, "data": merged]
            guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
                lastStatus = "Gönderilecek veri hazırlanamadı"
                return lastStatus
            }
            var put = URLRequest(url: url, timeoutInterval: 20)
            put.httpMethod = "PUT"
            put.setValue("application/json", forHTTPHeaderField: "Content-Type")
            put.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
            put.httpBody = body
            do {
                let (_, resp) = try await URLSession.shared.data(for: put)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if status == 409 {
                    // Bu arada bilgisayar yeni bir şey göndermiş → hiçbir şeyi silmeden tekrar birleştir
                    again = true
                    lastStatus = "Bilgisayarda yeni değişiklik var, birleştiriliyor"
                    return lastStatus
                }
                guard status == 200 else { lastStatus = "Gönderilemedi (\(status))"; return lastStatus }
                what.append("bilgisayara gönderildi")
            } catch {
                lastStatus = "Sunucuya ulaşılamadı"
                return lastStatus
            }
        }

        saveBase(merged)
        let time = Date().formatted(date: .omitted, time: .shortened)
        lastStatus = (what.isEmpty ? "Eşit" : "Eşitlendi (" + what.joined(separator: ", ") + ")") + " · " + time
        return lastStatus
    }

    // MARK: - İşaretler

    private func isDead(_ id: String) -> Bool {
        guard let t = tomb[id] else { return false }
        return t > (revived[id] ?? "")
    }

    private func buildMarks(base: JSON, local: JSON, remote: JSON) {
        let d = UserDefaults.standard
        tomb = d.dictionary(forKey: "syncTomb") as? [String: String] ?? [:]
        revived = d.dictionary(forKey: "syncRevived") as? [String: String] ?? [:]
        maxInto(&tomb, remote["deleted"] as? [String: String] ?? [:])
        maxInto(&revived, remote["revived"] as? [String: String] ?? [:])
        maxInto(&tomb, trashMarks(remote["trash"]))
        let localTrash = trashMarks(local["trash"])
        let now = Self.isoPlain.string(from: Date())
        var allLocal = Set<String>()
        for (key, nested) in Self.keys {
            let b = ids(base[key], nested), l = ids(local[key], nested)
            allLocal.formUnion(l)
            for id in b.subtracting(l) where !isDead(id) { tomb[id] = localTrash[id] ?? now }   // burada silindi
            for id in l.subtracting(b) where isDead(id) { revived[id] = now }                  // burada geri alındı
        }
        for (id, when) in localTrash where tomb[id] == nil && !allLocal.contains(id) { tomb[id] = when }
        let cutoff = Self.isoPlain.string(from: Date().addingTimeInterval(-60 * 86400))
        tomb = tomb.filter { $0.value >= cutoff }
        revived = revived.filter { $0.value >= cutoff }
        d.set(tomb, forKey: "syncTomb")
        d.set(revived, forKey: "syncRevived")
    }

    private func maxInto(_ dst: inout [String: String], _ src: [String: String]) {
        for (k, v) in src where !k.isEmpty && v > (dst[k] ?? "") { dst[k] = v }
    }

    private func trashMarks(_ trash: Any?) -> [String: String] {
        var out: [String: String] = [:]
        for e in trash as? [JSON] ?? [] {
            let when = normDate(e["deletedAt"]) ?? Self.isoPlain.string(from: Date())
            for k in ["task", "shopping", "call", "memory", "listItem", "list"] {
                guard let obj = e[k] as? JSON, let id = obj["id"] as? String else { continue }
                out[id] = when
                if k == "list" {
                    for it in obj["items"] as? [JSON] ?? [] { if let iid = it["id"] as? String { out[iid] = when } }
                }
            }
        }
        return out
    }

    private func ids(_ coll: Any?, _ nested: String?) -> Set<String> {
        var out = Set<String>()
        for x in coll as? [JSON] ?? [] {
            if let id = x["id"] as? String { out.insert(id) }
            if let nested {
                for it in x[nested] as? [JSON] ?? [] { if let id = it["id"] as? String { out.insert(id) } }
            }
        }
        return out
    }

    // MARK: - Kayıt kayıt birleştirme

    private func byID(_ coll: Any?) -> [String: JSON] {
        var out: [String: JSON] = [:]
        for x in coll as? [JSON] ?? [] { if let id = x["id"] as? String, out[id] == nil { out[id] = x } }
        return out
    }

    private func merge(_ base: Any?, _ local: Any?, _ remote: Any?, _ fields: [String],
                       nested: (String, [String])?) -> [JSON] {
        let b = byID(base), l = byID(local), r = byID(remote)
        var order: [String] = (remote as? [JSON] ?? []).compactMap { $0["id"] as? String }
        for x in local as? [JSON] ?? [] { if let id = x["id"] as? String, r[id] == nil { order.append(id) } }
        var seen = Set<String>()
        var out: [JSON] = []
        for id in order where !seen.contains(id) {
            seen.insert(id)
            if isDead(id) { continue }
            if let li = l[id], let ri = r[id] {
                let lc = proj(li, fields) != proj(b[id], fields)
                let rc = proj(ri, fields) != proj(b[id], fields)
                var item = ri
                if lc && !rc { item.merge(li) { _, new in new } }
                if let n = nested {
                    item[n.0] = merge(b[id]?[n.0], li[n.0], ri[n.0], n.1, nested: nil)
                }
                out.append(item)
            } else if let li = l[id] {
                out.append(li)                                   // sadece burada var → koru
            } else if let ri = r[id] {
                out.append(ri)                                   // sadece bilgisayarda var → ekle
            }
        }
        return out
    }

    private func union(_ a: Any?, _ b: Any?) -> [JSON] {
        var out: [JSON] = []
        var seen = Set<String>()
        for x in (a as? [JSON] ?? []) + (b as? [JSON] ?? []) {
            guard let id = x["id"] as? String, !seen.contains(id), !isDead(id) else { continue }
            seen.insert(id)
            out.append(x)
        }
        return out
    }

    // MARK: - Karşılaştırma

    private func normDate(_ v: Any?) -> String? {
        guard let s = v as? String, let d = Self.parse(s) else { return nil }
        return Self.isoPlain.string(from: d)
    }

    private func canon(_ v: Any?, date: Bool) -> String {
        guard let v, !(v is NSNull) else { return "" }
        if date, let d = normDate(v) { return d }
        if let s = v as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "1" : "" }
            return n.stringValue
        }
        return "\(v)"
    }

    private func proj(_ x: JSON?, _ fields: [String]) -> String {
        guard let x else { return "∅" }
        return fields.map { "\($0)=\(canon(x[$0], date: Self.dateKeys.contains($0)))" }.joined(separator: "|")
    }

    private func signature(_ coll: Any?, _ fields: [String], nested: (String, [String])?) -> [String] {
        (coll as? [JSON] ?? []).map { x in
            var s = "\(x["id"] as? String ?? "")#\(proj(x, fields))"
            if let n = nested { s += "#" + signature(x[n.0], n.1, nested: nil).joined(separator: ",") }
            return s
        }.sorted()
    }

    private func same(_ a: Any?, _ b: Any?, _ fields: [String]) -> Bool {
        signature(a, ["id"], nested: nil) == signature(b, ["id"], nested: nil)
    }

    private func same(_ a: JSON, _ b: JSON) -> Bool {
        signature(a["tasks"], Self.fTask, nested: nil) == signature(b["tasks"], Self.fTask, nested: nil)
            && signature(a["shopping"], Self.fShop, nested: nil) == signature(b["shopping"], Self.fShop, nested: nil)
            && signature(a["calls"], Self.fCall, nested: nil) == signature(b["calls"], Self.fCall, nested: nil)
            && signature(a["lists"], Self.fList, nested: ("items", Self.fItem))
                == signature(b["lists"], Self.fList, nested: ("items", Self.fItem))
            && signature(a["memory"], Self.fMem, nested: nil) == signature(b["memory"], Self.fMem, nested: nil)
    }

    // MARK: - Son eşitlenen hal (taban)

    private func loadBase() -> JSON {
        guard let data = try? Data(contentsOf: baseURL),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? JSON else { return [:] }
        return obj
    }

    private func saveBase(_ merged: JSON) {
        var b: JSON = [:]
        for (key, _) in Self.keys { b[key] = merged[key] ?? [] }
        if let data = try? JSONSerialization.data(withJSONObject: b) { try? data.write(to: baseURL, options: .atomic) }
    }
}
