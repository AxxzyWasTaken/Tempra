import AppKit
import Foundation
import TempraSensors

final class CPUTemperatureMonitor: @unchecked Sendable {
    private struct Reading {
        let temperature: Double
        let date: Date
    }

    private let queue = DispatchQueue(
        label: "app.tempra.cpu-temperature",
        qos: .utility
    )
    private let onFailure: @Sendable (String) -> Void
    private let lock = NSLock()
    private var reader: OpaquePointer?
    private var timer: DispatchSourceTimer?
    private var latestReading: Reading?
    private var activeInterval: TimeInterval?
    private var maximumReadingAge: TimeInterval = 10

    init(onFailure: @escaping @Sendable (String) -> Void) {
        self.onFailure = onFailure
    }

    convenience init() {
        self.init { message in
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "Tempra stopped"
                alert.informativeText = message
                alert.runModal()
                NSApp.terminate(nil)
            }
        }
    }

    var currentTemperatureCelsius: Double? {
        lock.withLock {
            guard let latestReading,
                  Date().timeIntervalSince(latestReading.date) <= maximumReadingAge else {
                return nil
            }
            return latestReading.temperature
        }
    }

    func start(samplingEvery interval: TimeInterval) {
        let normalizedInterval = max(1, interval)
        queue.async { [weak self] in
            self?.startSampling(interval: normalizedInterval)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopSampling()
        }
    }

    private func startSampling(interval: TimeInterval) {
        if activeInterval == interval, timer != nil {
            return
        }
        stopSampling(clearReading: false)
        activeInterval = interval
        lock.withLock {
            maximumReadingAge = max(10, interval * 2)
        }
        var createdReader: OpaquePointer?
        let status = TempraTemperatureReaderCreate(&createdReader)
        guard status.rawValue == 0, let createdReader else {
            fail(status: status, operation: "start")
            return
        }
        reader = createdReader
        guard sample() else { return }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        let leeway = min(1, max(0.15, interval * 0.1))
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(Int(leeway * 1_000))
        )
        timer.setEventHandler { [weak self] in
            self?.sample()
        }
        self.timer = timer
        timer.resume()
    }

    private func stopSampling(clearReading: Bool = true) {
        timer?.cancel()
        timer = nil
        activeInterval = nil
        if let reader {
            TempraTemperatureReaderDestroy(reader)
            self.reader = nil
        }
        if clearReading {
            lock.withLock {
                latestReading = nil
                maximumReadingAge = 10
            }
        }
    }

    @discardableResult
    private func sample() -> Bool {
        guard let reader else { return false }
        var temperature = 0.0
        let status = TempraTemperatureReaderReadCPU(reader, &temperature)
        guard status.rawValue == 0 else {
            fail(status: status, operation: "read")
            return false
        }
        lock.withLock {
            latestReading = Reading(temperature: temperature, date: Date())
        }
        return true
    }

    private func fail(status: TempraTemperatureReaderStatus, operation: String) {
        stopSampling()
        onFailure(
            "AppleSMC temperature \(operation) failed: "
                + Self.failureDescription(status)
                + " (code \(status.rawValue))."
        )
    }

    private static func failureDescription(
        _ status: TempraTemperatureReaderStatus
    ) -> String {
        switch status.rawValue {
        case 1: "invalid native argument"
        case 2: "reader allocation failed"
        case 3: "AppleSMC is unavailable"
        case 4: "no readable CPU temperature sensors were found"
        case 5: "all AppleSMC CPU sensor reads failed"
        default: "unknown native failure"
        }
    }
}
