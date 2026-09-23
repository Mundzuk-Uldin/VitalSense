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
    private let reader: HealthVitalsReader
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?
    private var passiveRefreshTask: Task<Void, Never>?

    override init() {
        reader = HealthVitalsReader(store: store)
        super.init()
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
                read: HealthVitalsReader.readTypes
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

    /// Heart rate arrives live from the workout session, so it is excluded
    /// here; everything else is whatever Health last recorded.
    func refreshPassiveVitals() async {
        var updated = reading
        await reader.populate(&updated, includeHeartRate: !isMonitoring)
        // The workout session may have delivered a live heart rate while
        // those queries were in flight. It is fresher than anything the
        // snapshot holds, so it wins.
        if isMonitoring {
            updated.heartRate = reading.heartRate
        }
        reading = updated
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
