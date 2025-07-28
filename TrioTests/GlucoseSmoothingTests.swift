import CoreData
import Foundation
import LoopKitUI
import Swinject
import Testing

@testable import Trio

@Suite("Glucose Smoothing Tests", .serialized) struct GlucoseSmoothingTests: Injectable {
    let resolver: Resolver
    var coreDataStack: CoreDataStack!
    var testContext: NSManagedObjectContext!
    var fetchGlucoseManager: BaseFetchGlucoseManager!
    var openAPS: OpenAPS!

    init() async throws {
        // Create test context
        coreDataStack = try await CoreDataStack.createForTests()
        testContext = coreDataStack.newTaskContext()

        // Create assembler with test assembly
        let assembler = Assembler([
            StorageAssembly(),
            ServiceAssembly(),
            APSAssembly(),
            NetworkAssembly(),
            UIAssembly(),
            SecurityAssembly(),
            TestAssembly(testContext: testContext)
        ])

        resolver = assembler.resolver
        injectServices(resolver)

        // Resolve the concrete type for testing
        fetchGlucoseManager = resolver.resolve(FetchGlucoseManager.self)! as? BaseFetchGlucoseManager

        // Manually create OpenAPS with the test context and other dependencies
        let fileStorage = resolver.resolve(FileStorage.self)!
        openAPS = OpenAPS(storage: fileStorage, tddStorage: MockTDDStorage())
    }

    // MARK: - Low-Pass Filter Tests

    /// Tests the core logic of the IIR low-pass filter used for smoothing glucose values.
    @Test("Low-pass filter calculates smoothed glucose correctly") func testLowPassFilterCalculation() async throws {
        // GIVEN: A sequence of glucose values at regular intervals
        let glucoseValues: [Int16] = [100, 105, 110, 115, 120]
        await createGlucoseSequence(values: glucoseValues, interval: 5 * 60) // 5-minute interval

        // WHEN: The low-pass filter is applied
        await fetchGlucoseManager.lowPassFilterGlucose(context: testContext)

        // THEN: The smoothedGlucose property should be correctly calculated for each entry after the first one.
        let fetchedGlucose = try await fetchAndSortGlucose()

        // The first value has no preceding value, so it cannot be smoothed.
        await testContext.perform {
            #expect(fetchedGlucose[0].smoothedGlucose == nil, "First glucose value should not be smoothed.")

            // Manually calculate the expected smoothed values for comparison.
            let timeConstant = 11.3 * 60.0
            let deltaTime = 5.0 * 60.0
            let alpha = Decimal(1 - exp(-deltaTime / timeConstant))

            var lastSmoothedValue = Decimal(fetchedGlucose[0].glucose)

            for i in 1 ..< fetchedGlucose.count {
                let currentRawValue = Decimal(fetchedGlucose[i].glucose)
                let expectedSmoothedValue = alpha * currentRawValue + (1 - alpha) * lastSmoothedValue
                lastSmoothedValue = expectedSmoothedValue

                let actualSmoothedValue = fetchedGlucose[i].smoothedGlucose as? Decimal
                #expect(actualSmoothedValue != nil, "Smoothed value at index \(i) should not be nil.")

                if let actualSmoothedValue = actualSmoothedValue {
                    #expect(
                        abs(actualSmoothedValue - expectedSmoothedValue) < 0.001,
                        "Smoothed value at index \(i) is incorrect. Expected \(expectedSmoothedValue), got \(actualSmoothedValue)."
                    )
                }
            }
        }
    }

    // MARK: - OpenAPS Glucose Selection Tests

    /// Verifies that the algorithm uses the `smoothedGlucose` value when the `smoothGlucose` setting is enabled.
    @Test("Algorithm uses smoothed glucose when enabled") func testAlgorithmUsesSmoothedGlucose() async throws {
        // GIVEN: A glucose entry with both raw and smoothed values
        await createGlucose(glucose: 150, smoothed: 140, isManual: false, date: Date())

        // WHEN: We process glucose with smoothing enabled
        let algorithmInput = try await runFetchAndProcessGlucose(smoothGlucose: true)

        // THEN: The processed glucose value should be the smoothed one.
        #expect(algorithmInput.count == 1, "Expected to process one glucose entry.")
        #expect(
            algorithmInput.first?.glucose == 140,
            "Algorithm should have used the smoothed glucose value (140), but used \(algorithmInput.first?.glucose ?? 0)."
        )
    }

    /// Verifies that the algorithm uses the raw `glucose` value when the `smoothGlucose` setting is disabled.
    @Test("Algorithm uses raw glucose when smoothing is disabled") func testAlgorithmUsesRawGlucose() async throws {
        // GIVEN: A glucose entry with both raw and smoothed values
        await createGlucose(glucose: 150, smoothed: 140, isManual: false, date: Date())

        // WHEN: We process glucose with smoothing disabled
        let algorithmInput = try await runFetchAndProcessGlucose(smoothGlucose: false)

        // THEN: The processed glucose value should be the raw one.
        #expect(algorithmInput.count == 1, "Expected to process one glucose entry.")
        #expect(
            algorithmInput.first?.glucose == 150,
            "Algorithm should have used the raw glucose value (150), but used \(algorithmInput.first?.glucose ?? 0)."
        )
    }

    /// Verifies that the algorithm falls back to the raw `glucose` value if smoothing is enabled but a smoothed value is not available.
    @Test("Algorithm falls back to raw glucose if smoothed value is missing") func testAlgorithmFallbackToRawGlucose() async throws {
        // GIVEN: A glucose entry with a raw value but no smoothed value
        await createGlucose(glucose: 150, smoothed: nil, isManual: false, date: Date())

        // WHEN: We process glucose with smoothing enabled
        let algorithmInput = try await runFetchAndProcessGlucose(smoothGlucose: true)

        // THEN: The processed glucose value should be the raw one.
        #expect(algorithmInput.count == 1, "Expected to process one glucose entry.")
        #expect(
            algorithmInput.first?.glucose == 150,
            "Algorithm should have fallen back to the raw glucose value (150), but used \(algorithmInput.first?.glucose ?? 0)."
        )
    }

    /// Verifies that the algorithm always uses the raw `glucose` value for manually entered data, regardless of the smoothing setting.
    @Test("Algorithm ignores smoothed value for manual glucose entries") func testAlgorithmIgnoresSmoothedManualGlucose() async throws {
        // GIVEN: A manual glucose entry with both raw and smoothed values
        await createGlucose(glucose: 150, smoothed: 140, isManual: true, date: Date())

        // WHEN: We process glucose with smoothing enabled
        let algorithmInput = try await runFetchAndProcessGlucose(smoothGlucose: true)

        // THEN: The processed glucose value should be the raw one, as manual entries are not smoothed.
        #expect(algorithmInput.count == 1, "Expected to process one glucose entry.")
        #expect(
            algorithmInput.first?.glucose == 150,
            "Algorithm should have ignored smoothing for a manual entry and used the raw value (150), but used \(algorithmInput.first?.glucose ?? 0)."
        )
    }

    // MARK: - Helper Functions

    /// A helper function to run the private `fetchAndProcessGlucose` method and decode its JSON output for testing.
    private func runFetchAndProcessGlucose(smoothGlucose: Bool) async throws -> [AlgorithmGlucose] {
        let jsonString = try await openAPS.fetchAndProcessGlucose(
            context: testContext,
            smoothGlucose: smoothGlucose,
            fetchLimit: 10
        )
        let data = jsonString.data(using: .utf8)!
        let decoder = JSONDecoder()
        // Dates are encoded as milliseconds since 1970, so we need a custom decoding strategy.
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateDouble = try container.decode(Double.self)
            return Date(timeIntervalSince1970: dateDouble / 1000)
        }
        return try decoder.decode([AlgorithmGlucose].self, from: data)
    }

    /// Creates a single `GlucoseStored` object in the test context.
    private func createGlucose(glucose: Int16, smoothed: Decimal?, isManual: Bool, date: Date) async {
        await testContext.perform {
            let object = GlucoseStored(context: self.testContext)
            object.date = date
            object.glucose = glucose
            object.smoothedGlucose = smoothed as NSDecimalNumber?
            object.isManual = isManual
            object.id = UUID()
            try! self.testContext.save()
        }
    }

    /// Creates a sequence of `GlucoseStored` objects for testing the filter.
    private func createGlucoseSequence(values: [Int16], interval: TimeInterval) async {
        let now = Date()
        await testContext.perform {
            for (index, value) in values.enumerated() {
                let object = GlucoseStored(context: self.testContext)
                object.date = now.addingTimeInterval(Double(index) * interval)
                object.glucose = value
                object.id = UUID()
            }
            try! self.testContext.save()
        }
    }

    /// Fetches and sorts all glucose entries from the test context.
    private func fetchAndSortGlucose() async throws -> [GlucoseStored] {
        try await coreDataStack.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: testContext,
            predicate: .all,
            key: "date",
            ascending: true
        ) as? [GlucoseStored] ?? []
    }
}
