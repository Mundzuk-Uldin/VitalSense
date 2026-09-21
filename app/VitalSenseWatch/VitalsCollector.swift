import Foundation
import HealthKit

/// Pulls vitals off the Apple Watch's sensors.
///
/// Series 9 measures four of the seven vitals NEWS2 wants, and each one on a
/// different schedule:
///
/// - **Heart rate** is the only one available continuously. A background
///   `HKWorkoutSession` is what raises the sampling rate from "every few
///   minutes when it feels like it" to roughly once per second, which is why
///   monitoring starts one even though no exercise is happening.
/// - **Blood oxygen** is sampled in the background at rest. On units sold in
///   the US after January 2024 the sensor is disabled outright, so this can
///   legitimately never arrive.
/// - **Respiratory rate** is derived during sleep only.
/// - **Wrist temperature** is derived during sleep only, and is a *wrist*
///   temperature -- see `estimatedBodyTemperature()`.
///
/// Anything we do not get keeps its assumed value and is flagged as such,
/// because a fabricated normal reading presented as a measurement is worse
/// than an obvious gap.
@MainActor
final class VitalsCollector: NSObject, ObservableObject {

    @Published private(set) var reading = VitalsReading()
    @Published private(set) var isMonitoring = false
    @Published private(set) var isAuthorized = false
    @Published private(set) var statusMessage = "Not started"
    @Published private(set) var errorMessage: String?

    private let store = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?
    private var passiveRefreshTask: Task<Void, Never>?

    /// Baseline for the wrist-temperature deviation. Needs several nights of
    /// data before it means anything.
    private static let minimumBaselineSamples = 3
    private static let assumedNormalCoreTemperature = 37.0

    private static var quantityTypes: [HKQuantityTypeIdentifier] {
        [.heartRate, .oxygenSaturation, .respiratoryRate, .bodyTemperature,
         .appleSleepingWristTemperature]
    }

    private var readTypes: Set<HKObjectType> {
        Set(Self.quantityTypes.map { HKQuantityType($0) as HKObjectType })
    }

    // MARK: - Authorization

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            errorMessage = "Health data is not available on this device."
            return
        }
        do {
            // The workout session writes a workout, so it needs share access
            // as well as read access to the vitals themselves.
            try await store.requestAuthorization(
                toShare: [HKObjectType.workoutType()],
                read: readTypes
            )
            isAuthorized = true
            statusMessage = "Ready"
            await refreshPassiveVitals()
        } catch {
            errorMessage = "Health access was refused. \(error.localizedDescription)"
        }
    }

    // MARK: - Monitoring

    func startMonitoring() {
        guard !isMonitoring else { return }
        errorMessage = nil

        let configuration = HKWorkoutConfiguration()
        // `.other` keeps the session honest -- we want the sensor cadence, not
        // to claim the wearer is exercising.
        configuration.activityType = .other
        configuration.locationType = .indoor

        do {
            let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(
                healthStore: store,
                workoutConfiguration: configuration
            )
            session.delegate = self
            builder.delegate = self

            let start = Date()
            session.startActivity(with: start)
            builder.beginCollection(withStart: start) { [weak self] _, error in
                Task { @MainActor in
                    if let error {
                        self?.errorMessage = "Could not start collecting: \(error.localizedDescription)"
                    }
                }
            }

            workoutSession = session
            workoutBuilder = builder
            isMonitoring = true
            statusMessage = "Monitoring"
            startPassiveRefresh()
        } catch {
            errorMessage = "Could not start the sensor session. \(error.localizedDescription)"
        }
    }

    func stopMonitoring() {
        guard isMonitoring else { return }
        passiveRefreshTask?.cancel()
        passiveRefreshTask = nil

        let end = Date()
        // Hold the builder locally: the completion handler runs off the main
        // actor, so it must not reach back into main-actor state to find it.
        let builder = workoutBuilder
        workoutSession?.end()
        builder?.endCollection(withEnd: end) { _, _ in
            // Discard rather than save: this was never a real workout, and
            // leaving a stub in the user's activity history would be rude.
            builder?.discardWorkout()
        }
        workoutSession = nil
        workoutBuilder = nil
        isMonitoring = false
        statusMessage = "Stopped"
    }

    /// The sleep-derived vitals change at most once a day, but blood oxygen
    /// can land at any time, so a slow poll is enough.
    private func startPassiveRefresh() {
        passiveRefreshTask?.cancel()
        passiveRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshPassiveVitals()
                try? await Task.sleep(nanoseconds: 60 * NSEC_PER_SEC)
            }
        }
    }

    func refreshPassiveVitals() async {
        // Blood oxygen is stored as a fraction, not a percentage.
        if let (value, date) = await latestSample(
            .oxygenSaturation, unit: .percent(), within: .hours(12)
        ) {
            reading.oxygenSaturation = Vital(value * 100, provenance: .sensor, sampledAt: date)
        }

        if let (value, date) = await latestSample(
            .respiratoryRate, unit: HKUnit.count().unitDivided(by: .minute()), within: .hours(36)
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
    /// healthy person. Feeding that number straight into NEWS2 scores 3
    /// points for hypothermia on someone who is perfectly well. Apple's own
    /// Health app never shows the absolute value either -- it shows a
    /// *deviation* from the wearer's personal baseline.
    ///
    /// So: prefer a real body temperature if one has been logged, otherwise
    /// convert the wrist reading into a deviation from the wearer's own
    /// trailing baseline and apply that deviation to a normal core
    /// temperature. With too few nights to form a baseline, return nothing
    /// and let the caller keep its assumed value.
    private func estimatedBodyTemperature() async -> Vital? {
        if let (value, date) = await latestSample(
            .bodyTemperature, unit: .degreeCelsius(), within: .hours(12)
        ) {
            return Vital(value, provenance: .sensor, sampledAt: date)
        }

        let history = await samples(
            .appleSleepingWristTemperature, unit: .degreeCelsius(), within: .days(30), limit: 30
        )
        guard let latest = history.first, history.count >= Self.minimumBaselineSamples else {
            return nil
        }

        let baselineSamples = history.dropFirst()
        let baseline = baselineSamples.reduce(0.0) { $0 + $1.value } / Double(baselineSamples.count)
        // Clamp: a wrist deviation beyond a few degrees is an artefact of a
        // loose band or a cold room, not a fever.
        let deviation = min(max(latest.value - baseline, -3.0), 3.0)
        return Vital(
            Self.assumedNormalCoreTemperature + deviation,
            provenance: .sensor,
            sampledAt: latest.date
        )
    }

    // MARK: - HealthKit queries

    private func latestSample(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        within window: TimeInterval
    ) async -> (value: Double, date: Date)? {
        await samples(identifier, unit: unit, within: window, limit: 1).first
    }

    private func samples(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        within window: TimeInterval,
        limit: Int
    ) async -> [(value: Double, date: Date)] {
        let type = HKQuantityType(identifier)
        let predicate = HKQuery.predicateForSamples(
            withStart: Date().addingTimeInterval(-window),
            end: Date(),
            options: .strictEndDate
        )
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: limit,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                let values = (samples as? [HKQuantitySample] ?? []).map {
                    (value: $0.quantity.doubleValue(for: unit), date: $0.endDate)
                }
                continuation.resume(returning: values)
            }
            store.execute(query)
        }
    }

    // MARK: - Demo mode

    /// The Simulator has no HealthKit data whatsoever, and a real watch can
    /// take a night's sleep to produce three of these four numbers. Demo mode
    /// keeps the app presentable in both cases -- and marks the reading's
    /// source as `demo` so nothing downstream mistakes it for a measurement.
    func loadDemoReading(risk: String) {
        stopMonitoring()
        reading = .demo(risk: risk)
        statusMessage = "Demo reading (\(risk))"
    }
}

// MARK: - Live sample delivery

extension VitalsCollector: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        let heartRateType = HKQuantityType(.heartRate)
        guard collectedTypes.contains(heartRateType),
              let statistics = workoutBuilder.statistics(for: heartRateType),
              let quantity = statistics.mostRecentQuantity()
        else { return }

        let beatsPerMinute = quantity.doubleValue(
            for: HKUnit.count().unitDivided(by: .minute())
        )
        let sampledAt = statistics.mostRecentQuantityDateInterval()?.end ?? Date()

        Task { @MainActor [weak self] in
            self?.reading.heartRate = Vital(
                beatsPerMinute, provenance: .sensor, sampledAt: sampledAt
            )
            self?.reading.recordedAt = Date()
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}

extension VitalsCollector: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor [weak self] in
            if toState == .ended || toState == .stopped {
                self?.isMonitoring = false
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.errorMessage = "Sensor session ended: \(error.localizedDescription)"
            self?.isMonitoring = false
        }
    }
}

private extension TimeInterval {
    static func hours(_ count: Double) -> TimeInterval { count * 3600 }
    static func days(_ count: Double) -> TimeInterval { count * 86_400 }
}
