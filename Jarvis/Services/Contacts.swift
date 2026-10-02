import Foundation
import Contacts
import UIKit

/// Aranacaklar listesindeki kişiyi rehberde bulup tek dokunuşla arar.
@MainActor
enum ContactsService {
    static func call(_ person: String) async -> Bool {
        let store = CNContactStore()
        let granted = (try? await store.requestAccess(for: .contacts)) ?? false
        guard granted else { return false }

        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
        let words = person.split(separator: " ").map(String.init)
        var candidates: [CNContact] = []
        for query in [person] + words.filter({ $0.count > 2 }) {
            let found = (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: query), keysToFetch: keys)) ?? []
            candidates = found.filter { !$0.phoneNumbers.isEmpty }
            if !candidates.isEmpty { break }
        }
        guard let contact = candidates.first, let number = contact.phoneNumbers.first?.value.stringValue else { return false }
        let digits = number.filter { $0.isNumber || $0 == "+" }
        guard let url = URL(string: "tel://\(digits)") else { return false }
        await UIApplication.shared.open(url)
        return true
    }
}
