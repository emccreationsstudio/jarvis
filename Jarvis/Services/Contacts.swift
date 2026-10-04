import Foundation
import Contacts
import UIKit

/// Aranacaklar listesindeki kişiyi rehberde bulup tek dokunuşla arar.
@MainActor
enum ContactsService {
    /// Kişiyi (ya da doğrudan söylenen numarayı: 112, 155…) arar
    static func call(_ person: String) async -> Bool {
        let digits = person.filter { $0.isNumber || $0 == "+" }
        // Yalnızca numara söylendiyse (acil numaralar dahil) rehbere bakmadan ara; iPhone onay sorar
        if digits.count >= 3 && digits.count * 2 >= person.filter({ !$0.isWhitespace }).count {
            guard let url = URL(string: "tel://\(digits)") else { return false }
            await UIApplication.shared.open(url)
            return true
        }
        guard let number = await phoneNumber(for: person), let url = URL(string: "tel://\(number)") else { return false }
        await UIApplication.shared.open(url)
        return true
    }

    /// Mesajlar (ya da WhatsApp) hazır metinle açılır; göndermek için tek dokunuş yeter
    static func message(_ person: String, text: String, whatsapp: Bool) async -> Bool {
        guard let number = await phoneNumber(for: person) else { return false }
        let body = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=?+"))) ?? ""
        if whatsapp {
            // WhatsApp ülke koduyla ister: 0555… → 90555…
            var wa = number.replacingOccurrences(of: "+", with: "")
            if wa.hasPrefix("0") { wa = "90" + wa.dropFirst() }
            if let url = URL(string: "whatsapp://send?phone=\(wa)&text=\(body)"), UIApplication.shared.canOpenURL(url) {
                await UIApplication.shared.open(url)
                return true
            }
        }
        guard let url = URL(string: "sms:\(number)&body=\(body)") else { return false }
        await UIApplication.shared.open(url)
        return true
    }

    /// Rehberde kişinin ilk telefon numarası (yalnızca rakamlar ve +)
    static func phoneNumber(for person: String) async -> String? {
        let store = CNContactStore()
        let granted = (try? await store.requestAccess(for: .contacts)) ?? false
        guard granted else { return nil }

        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
        let words = person.split(separator: " ").map(String.init)
        var candidates: [CNContact] = []
        for query in [person] + words.filter({ $0.count > 2 }) {
            let found = (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: query), keysToFetch: keys)) ?? []
            candidates = found.filter { !$0.phoneNumbers.isEmpty }
            if !candidates.isEmpty { break }
        }
        guard let contact = candidates.first else { return nil }
        // Cep numarasını tercih et
        let mobile = contact.phoneNumbers.first { ($0.label ?? "").lowercased().contains("mobile") || ($0.label ?? "").contains("iPhone") }
        guard let number = (mobile ?? contact.phoneNumbers.first)?.value.stringValue else { return nil }
        let digits = number.filter { $0.isNumber || $0 == "+" }
        return digits.isEmpty ? nil : digits
    }
}
