import CoreML
import Foundation

/// Runs the fastai-trained model on the device.
///
/// There is no server and no network in this path. The model is a 17 KB
/// Core ML graph in the app bundle, small enough to live on a watch, so a
/// reading is scored the moment it is taken — on a plane, in a basement, or
/// on conference Wi-Fi that blocks everything.
///
/// Normalisation is baked into the exported graph, so this passes raw vitals
/// and does not have to keep a copy of the training means and standard
/// deviations in sync.
final class RiskScorer {

    enum Failure: LocalizedError {
        case modelMissing
        case modelUnreadable(String)
        case predictionFailed(String)
        case malformedOutput

        var errorDescription: String? {
            switch self {
            case .modelMissing:
                return "The risk model is missing from the app bundle."
            case .modelUnreadable(let message):
                return "The risk model could not be loaded. \(message)"
            case .predictionFailed(let message):
                return "The model could not score this reading. \(message)"
            case .malformedOutput:
                return "The model returned an unexpected result."
            }
        }
    }

    /// The class order the model emits, which fastai sorts alphabetically.
    /// This is *not* clinical order — `RiskLevel.allCases` is.
    static let modelClassOrder: [RiskLevel] = [.high, .low, .medium, .normal]

    /// fastai reserves index 0 of every categorical column for unseen
    /// values, so the real levels start at 1.
    static let consciousnessIndex: [Consciousness: Int] = [
        .alert: 1, .confusion: 2, .pain: 3, .unresponsive: 4, .voice: 5,
    ]

    private static let continuousFeatureCount = 10

    private let model: MLModel
    let version: String

    /// Loads `VitalRisk.mlmodelc` from a bundle.
    ///
    /// - Parameter bundle: defaults to the app bundle; the command-line
    ///   checker passes a directory instead.
    convenience init(bundle: Bundle = .main) throws {
        guard let url = bundle.url(forResource: "VitalRisk", withExtension: "mlmodelc") else {
            throw Failure.modelMissing
        }
        try self.init(compiledModelURL: url)
    }

    init(compiledModelURL url: URL) throws {
        do {
            let configuration = MLModelConfiguration()
            // A ten-input MLP is far too small for the Neural Engine to be
            // worth waking; the CPU answers faster and uses less power.
            configuration.computeUnits = .cpuOnly
            self.model = try MLModel(contentsOf: url, configuration: configuration)
        } catch {
            throw Failure.modelUnreadable(error.localizedDescription)
        }
        self.version = Self.readVersion(from: model)
    }

    private static func readVersion(from model: MLModel) -> String {
        let metadata = model.modelDescription.metadata
        if let description = metadata[.description] as? String, !description.isEmpty {
            return "fastai · on-device"
        }
        return "on-device"
    }

    // MARK: - Scoring

    func score(_ reading: VitalsReading) throws -> RiskPrediction {
        let components = NEWS2.components(for: reading)
        let probabilities = try probabilities(for: reading, components: components)

        let level = probabilities.max { $0.value < $1.value }?.key ?? NEWS2.band(components)
        let factors = components
            .map { RiskFactor(component: $0) }
            .sorted { ($0.score, $1.label) > ($1.score, $0.label) }

        let contributing = factors.filter { $0.score > 0 }
        let topFactors = contributing.isEmpty
            ? ["No vital is outside its normal range."]
            : contributing.prefix(3).map { "\($0.label): \($0.displayValue)" }

        return RiskPrediction(
            riskLevel: level,
            confidence: probabilities[level] ?? 0,
            probabilities: probabilities,
            news2Total: NEWS2.aggregate(components),
            news2Band: NEWS2.band(components),
            hasRedScore: NEWS2.hasRedScore(components),
            riskFactors: factors,
            topFactors: Array(topFactors),
            recommendation: NEWS2.recommendation(for: level),
            modelVersion: version,
            predictedAt: Date()
        )
    }

    private func probabilities(
        for reading: VitalsReading,
        components: [NEWS2.Component]
    ) throws -> [RiskLevel: Double] {
        // This order is the contract with `model/train.py`. Change one side
        // and the model silently scores garbage, which is why
        // `tools/check_model.sh` replays frozen reference cases.
        let continuous: [Double] = [
            reading.respiratoryRate.value,
            reading.oxygenSaturation.value,
            Double(reading.o2Scale),
            reading.systolicBP.value,
            reading.heartRate.value,
            reading.temperature.value,
            reading.onOxygen ? 1 : 0,
            Double(NEWS2.aggregate(components)),
            Double(NEWS2.maxComponent(components)),
            Double(NEWS2.abnormalCount(components)),
        ]
        assert(continuous.count == Self.continuousFeatureCount)

        let continuousArray = try MLMultiArray(
            shape: [1, NSNumber(value: Self.continuousFeatureCount)], dataType: .float32
        )
        for (index, value) in continuous.enumerated() {
            continuousArray[index] = NSNumber(value: Float(value))
        }

        let categoricalArray = try MLMultiArray(shape: [1, 1], dataType: .float32)
        categoricalArray[0] = NSNumber(
            value: Float(Self.consciousnessIndex[reading.consciousness] ?? 0)
        )

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "continuous": MLFeatureValue(multiArray: continuousArray),
            "categorical": MLFeatureValue(multiArray: categoricalArray),
        ])

        let output: MLFeatureProvider
        do {
            output = try model.prediction(from: input)
        } catch {
            throw Failure.predictionFailed(error.localizedDescription)
        }

        guard let result = output.featureValue(for: "probabilities")?.multiArrayValue,
              result.count == Self.modelClassOrder.count
        else {
            throw Failure.malformedOutput
        }

        var probabilities: [RiskLevel: Double] = [:]
        for (index, level) in Self.modelClassOrder.enumerated() {
            probabilities[level] = result[index].doubleValue
        }
        return probabilities
    }
}

private extension RiskFactor {
    init(component: NEWS2.Component) {
        let label = component.vital.label
        self.init(
            name: component.vital.rawValue,
            label: label,
            value: component.value,
            displayValue: component.detail,
            score: component.score,
            severity: component.severity,
            note: component.score == 0
                ? "Within normal range."
                : "\(component.detail.prefix(1).uppercased())\(component.detail.dropFirst()) "
                    + "contributes \(component.score) point\(component.score == 1 ? "" : "s") "
                    + "to the early-warning score.",
            symbolName: component.vital.symbolName
        )
    }
}
