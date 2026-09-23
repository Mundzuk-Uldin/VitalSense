import Foundation
import HealthKit

/// Reads vitals out of HealthKit.
///
/// Used by both apps. The iPhone matters most: an Apple Watch writes heart
/// rate, blood oxygen, respiratory rate and wrist temperature into the
/// shared Health database and they sync to the phone automatically. So the
/// iPhone can read everything the watch measured **without a watch app
/// installed at all** — the watch app only adds live, second-by-second
/// heart rate while you are actively monitoring.
actor HealthVitalsReader {

    /// Everything either app ever reads.
    static var readTypes: Set<HKObjectType> {
        Set(
            [
                HKQuantityTypeIdentifier.heartRate,
                .oxygenSaturation,
                .respiratoryRate,
                .bodyTemperature,
                .appleSleepingWristTemperature,
            ].map { HKQuantityType($0) as HKObjectType }
        )
    }

    private let store: HKHealthStore

    /// Baseline needs several nights before a deviation means anything.
    private static let minimumBaselineSamples = 3
    private static let assumedNormalCoreTemperature = 37.0

    init(store: HKHealthStore) {
        self.store = store
    }

    /// Fill in whatever HealthKit can supply, leaving the rest untouched so
    /// it keeps its assumed value and its honest `assumed` provenance.
    func populate(_ reading: inout VitalsReading, includeHeartRate: Bool) async {
        if includeHeartRate,
           let (value, date) = await latest(
               .heartRate, unit: .count().unitDivided(by: .minute()), within: .hours(6)
           ) {
            reading.heartRate = Vital(value, provenance: .sensor, sampledAt: date)
        }

        // Blood oxygen is stored as a fraction, not a percentage.
        if let (value, date) = await latest(.oxygenSaturation, unit: .percent(), within: .hours(24)) {
            reading.oxygenSaturation = Vital(value * 100, provenance: .sensor, sampledAt: date)
        }

        if let (value, date) = await latest(
            .respiratoryRate, unit: .count().unitDivided(by: .minute()), within: .hours(36)
        ) {
            reading.respiratoryRate = Vital(value, provenance: .sensor, sampledAt: date)
        }

        if let temperature = await estimatedBodyTemperature() {
            reading.temperature = temperature
        }

        reading.recordedAt = Date()
    }

    /// Turn a wrist temperature into something NEWS2 can score.
    ///
    /// This is the subtlest part of the app. `appleSleepingWristTemperature`
    /// is skin temperature at the wrist, which sits around 33-35 °C in a
    /// healthy person. Feeding that straight into NEWS2 scores 3 points for
    /// hypothermia on someone who is perfectly well. Apple's own Health app
    /// never shows the absolute value either — it shows a *deviation* from
    /// the wearer's personal baseline.
    ///
    /// So: prefer a real body temperature if one has been logged, otherwise
    /// convert the wrist reading into a deviation from the wearer's own
    /// trailing baseline and apply that to a normal core temperature. With
    /// too few nights to form a baseline, return nothing and let the caller
    /// keep its assumed value rather than invent a fever.
    func estimatedBodyTemperature() async -> Vital? {
        if let (value, date) = await latest(.bodyTemperature, unit: .degreeCelsius(), within: .hours(12)) {
            return Vital(value, provenance: .sensor, sampledAt: date)
        }

        let history = await samples(
            .appleSleepingWristTemperature, unit: .degreeCelsius(), within: .days(30), limit: 30
        )
        guard let newest = history.first, history.count >= Self.minimumBaselineSamples else {
            return nil
        }

        let baselineSamples = history.dropFirst()
        let baseline = baselineSamples.reduce(0.0) { $0 + $1.value } / Double(baselineSamples.count)
        // Clamp: a wrist deviation beyond a few degrees is a loose band or a
        // cold room, not a fever.
        let deviation = min(max(newest.value - baseline, -3.0), 3.0)
        return Vital(
            Self.assumedNormalCoreTemperature + deviation,
            provenance: .sensor,
            sampledAt: newest.date
        )
    }

    // MARK: - Queries

    func latest(
        _ identifier: HKQuantityTypeIdentifier, unit: HKUnit, within window: TimeInterval
    ) async -> (value: Double, date: Date)? {
        await samples(identifier, unit: unit, within: window, limit: 1).first
    }

    func samples(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        within window: TimeInterval,
        limit: Int
    ) async -> [(value: Double, date: Date)] {
        let predicate = HKQuery.predicateForSamples(
            withStart: Date().addingTimeInterval(-window), end: Date(), options: .strictEndDate
        )
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKQuantityType(identifier),
                predicate: predicate,
                limit: limit,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                continuation.resume(
                    returning: (samples as? [HKQuantitySample] ?? []).map {
                        (value: $0.quantity.doubleValue(for: unit), date: $0.endDate)
                    }
                )
            }
            store.execute(query)
        }
    }
}

extension TimeInterval {
    static func hours(_ count: Double) -> TimeInterval { count * 3600 }
    static func days(_ count: Double) -> TimeInterval { count * 86_400 }
}
