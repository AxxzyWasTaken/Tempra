import Foundation
import Testing
@testable import Tempra

@Suite("Timed averages")
struct TimedAverageTests {
    @Test("Samples expire by elapsed time instead of sample count")
    func elapsedWindow() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var average = TimedAverage()
        average.add(100, at: start, window: 60)
        average.add(20, at: start.addingTimeInterval(30), window: 60)
        #expect(average.value == 60)

        average.add(40, at: start.addingTimeInterval(61), window: 60)
        #expect(average.value == 30)
    }
}
