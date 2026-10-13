import Foundation
import Combine

struct WeatherNow: Equatable {
    var city: String
    var temperature: Double
    var high: Double
    var low: Double
    var code: Int
    var isDay: Bool

    /// SF Symbol for a WMO weather code.
    var symbol: String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 65, 67, 82: return "cloud.heavyrain.fill"
        case 61...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }
}

/// Weather from Open-Meteo (free, no key). Only the city name and its coordinates are sent.
@MainActor
final class WeatherService: ObservableObject {
    enum Status: Equatable { case noCity, loading, cityNotFound, offline, ready(WeatherNow) }

    @Published private(set) var status: Status = .noCity

    private let settings: Settings
    private var lastFetch: Date?
    private var task: Task<Void, Never>?
    private var cancellable: AnyCancellable?

    init(settings: Settings) {
        self.settings = settings
        cancellable = settings.$city
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh(force: true) }
            }
    }

    /// Refreshes if the data is older than 30 minutes (or if forced).
    func refresh(force: Bool = false) {
        if !force, let lastFetch, Date().timeIntervalSince(lastFetch) < 30 * 60, case .ready = status { return }
        let city = settings.city.trimmingCharacters(in: .whitespaces)
        guard !city.isEmpty else { status = .noCity; return }
        if case .ready = status {} else { status = .loading }
        task?.cancel()
        task = Task {
            let result = await Self.fetch(city: city)
            guard !Task.isCancelled else { return }
            status = result
            if case .ready = result { lastFetch = Date() }
        }
    }

    private struct GeoResponse: Decodable {
        struct Place: Decodable { let name: String; let latitude: Double; let longitude: Double }
        let results: [Place]?
    }

    private struct ForecastResponse: Decodable {
        struct Current: Decodable { let temperature_2m: Double; let weather_code: Int; let is_day: Int }
        struct Daily: Decodable { let temperature_2m_max: [Double]; let temperature_2m_min: [Double] }
        let current: Current
        let daily: Daily
    }

    private static func fetch(city: String) async -> Status {
        var geo = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        geo.queryItems = [URLQueryItem(name: "name", value: city), URLQueryItem(name: "count", value: "1"),
                          URLQueryItem(name: "format", value: "json")]
        guard let g = try? await Net.session.data(from: geo.url!) else { return .offline }
        guard let place = (try? JSONDecoder().decode(GeoResponse.self, from: g.0))?.results?.first else {
            return .cityNotFound
        }

        var forecast = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        forecast.queryItems = [
            URLQueryItem(name: "latitude", value: String(place.latitude)),
            URLQueryItem(name: "longitude", value: String(place.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "forecast_days", value: "1"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        guard let f = try? await Net.session.data(from: forecast.url!),
              let r = try? JSONDecoder().decode(ForecastResponse.self, from: f.0) else { return .offline }
        return .ready(WeatherNow(city: place.name, temperature: r.current.temperature_2m,
                                 high: r.daily.temperature_2m_max.first ?? r.current.temperature_2m,
                                 low: r.daily.temperature_2m_min.first ?? r.current.temperature_2m,
                                 code: r.current.weather_code, isDay: r.current.is_day == 1))
    }
}
