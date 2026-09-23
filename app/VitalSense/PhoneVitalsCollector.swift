import Foundation
import HealthKit

/// Reads the latest vitals on the iPhone.
///
/// An Apple Watch writes its measurements into the Health database and they
/// sync to the phone on their own, so this gets the same four vitals the
/// watch app would send — **with no watch app installed**. That makes the
/// iPhone app a complete product by itself, and the watch app an optional
/// extra for live monitoring.
@MainActor
final class PhoneVitalsCollector: ObservableObject {

    @Published private(set) var isAuthorized = false
    @Published private(set) var isReading = false
    @Published private(set) var errorMessage: String?

    private let store = HKHealthStore()
    private let reader: HealthVitalsReader

    init() {
        reader = HealthVitalsReader(store: store)
    }

    var isHealthAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAuthorization() async {
        guard isHealthAvailable else {
            errorMessage = "Health data is not available on this device."
            return
        }
        do {
            // Read-only: the phone never writes to Health.
            try await store.requestAuthorization(toShare: [], read: HealthVitalsReader.readTypes)
            isAuthorized = true
            errorMessage = nil
        } catch {
            errorMessage = "Health access was refused. \(error.localizedDescription)"
        }
    }

    /// Build a reading from whatever Health currently holds.
    ///
    /// HealthKit gives no way to tell "you denied this" from "there is no
    /// data", so a reading with nothing in it is reported as an empty
    /// reading rather than as an error — the UI shows which vitals are
    /// assumed, which is the honest answer either way.
    func read() async -> VitalsReading {
        isReading = true
        defer { isReading = false }

        var reading = VitalsReading(source: "health")
        await reader.populate(&reading, includeHeartRate: true)
        return reading
    }
}
