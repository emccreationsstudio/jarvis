import Foundation
import MapKit
import CoreLocation
import UIKit

/// Canlı trafiğe göre araçla yol süresi (Apple Haritalar).
@MainActor
final class RouteService: NSObject, CLLocationManagerDelegate {
    static let shared = RouteService()
    private let location = CLLocationManager()
    private var authCont: CheckedContinuation<Void, Never>?

    struct Result {
        let summary: String
        let destination: MKMapItem
        let origin: MKMapItem?
    }

    override init() {
        super.init()
        location.delegate = self
    }

    func requestPermission() async {
        guard location.authorizationStatus == .notDetermined else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            authCont = cont
            location.requestWhenInUseAuthorization()
        }
    }

    // MARK: Yaklaşık konum (hava durumu için)

    /// Son bilinen konum (izin yoksa nil)
    func approximateCoordinate() -> (lat: Double, lon: Double)? {
        guard hasLocation, let loc = location.location else { return nil }
        // Hava durumu için kabaca yeterli: ~1 km'ye yuvarla
        let lat = (loc.coordinate.latitude * 100).rounded() / 100
        let lon = (loc.coordinate.longitude * 100).rounded() / 100
        return (lat, lon)
    }

    /// Uygulama açılınca konumu bir kez tazele
    func refreshLocation() {
        guard hasLocation else { return }
        location.desiredAccuracy = kCLLocationAccuracyKilometer
        location.requestLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if manager.authorizationStatus != .notDetermined {
                self.authCont?.resume()
                self.authCont = nil
            }
        }
    }

    private var hasLocation: Bool {
        let s = location.authorizationStatus
        return s == .authorizedWhenInUse || s == .authorizedAlways
    }

    private func search(_ query: String) async -> MKMapItem? {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        if let loc = location.location {
            req.region = MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 80_000, longitudinalMeters: 80_000)
        }
        let res = try? await MKLocalSearch(request: req).start()
        return res?.mapItems.first
    }

    func route(from origin: String?, to destination: String) async -> Result? {
        await requestPermission()
        guard let dest = await search(destination) else { return nil }

        let req = MKDirections.Request()
        var originItem: MKMapItem? = nil
        if let origin, !origin.isEmpty {
            guard let o = await search(origin) else { return nil }
            originItem = o
            req.source = o
        } else {
            guard hasLocation else { return nil }
            req.source = MKMapItem.forCurrentLocation()
        }
        req.destination = dest
        req.transportType = .automobile
        req.departureDate = Date()
        req.requestsAlternateRoutes = true

        guard let response = try? await MKDirections(request: req).calculate(),
              let best = response.routes.min(by: { $0.expectedTravelTime < $1.expectedTravelTime }) else { return nil }

        let destName = dest.name ?? destination
        var text = "\(destName)"
        if let origin, !origin.isEmpty { text += " (\(origin) çıkışlı)" }
        text += ": şu an trafikle yaklaşık \(Self.duration(best.expectedTravelTime))"
        let km = best.distance / 1000
        text += String(format: ", %.0f kilometre", km)
        if !best.name.isEmpty { text += ". En hızlısı \(best.name) üzerinden" }
        if response.routes.count > 1,
           let second = response.routes.filter({ $0 !== best }).min(by: { $0.expectedTravelTime < $1.expectedTravelTime }) {
            let diff = Int((second.expectedTravelTime - best.expectedTravelTime) / 60)
            if diff >= 3, !second.name.isEmpty { text += "; \(second.name) yolu \(diff) dakika daha uzun" }
        }
        text += "."
        return Result(summary: text, destination: dest, origin: originItem)
    }

    func openInMaps(_ result: Result) {
        Task { await open(destination: result.destination, origin: result.origin) }
    }

    /// "Haritayı aç", "yol tarifi başlat" → seçilen harita uygulamasında doğrudan yol tarifi
    func openDirections(to destination: String, from origin: String?) async -> Bool {
        await requestPermission()
        guard let dest = await search(destination) else { return false }
        var originItem: MKMapItem? = nil
        if let origin, !origin.isEmpty { originItem = await search(origin) }
        await open(destination: dest, origin: originItem)
        return true
    }

    private func open(destination: MKMapItem, origin: MKMapItem?) async {
        let c = destination.placemark.coordinate
        let app = AppSettings.shared.mapsApp
        var url: URL?
        switch app {
        case "google":
            var s = "comgooglemaps://?daddr=\(c.latitude),\(c.longitude)&directionsmode=driving"
            if let o = origin?.placemark.coordinate { s += "&saddr=\(o.latitude),\(o.longitude)" }
            url = URL(string: s)
        case "yandex":
            var s = "yandexnavi://build_route_on_map?lat_to=\(c.latitude)&lon_to=\(c.longitude)"
            if let o = origin?.placemark.coordinate { s += "&lat_from=\(o.latitude)&lon_from=\(o.longitude)" }
            url = URL(string: s)
        default:
            url = nil
        }
        if let url, UIApplication.shared.canOpenURL(url) {
            await UIApplication.shared.open(url)
            return
        }
        // Apple Haritalar (seçilen uygulama yüklü değilse de)
        let opts = [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving]
        if let origin {
            MKMapItem.openMaps(with: [origin, destination], launchOptions: opts)
        } else {
            destination.openInMaps(launchOptions: opts)
        }
    }

    static func duration(_ t: TimeInterval) -> String {
        let mins = Int((t / 60).rounded())
        if mins < 60 { return "\(mins) dakika" }
        let h = mins / 60, m = mins % 60
        return m == 0 ? "\(h) saat" : "\(h) saat \(m) dakika"
    }
}

extension String {
    var capitalizedFirst: String {
        guard let f = first else { return self }
        return String(f).uppercased(with: Locale(identifier: "tr_TR")) + dropFirst()
    }
}
