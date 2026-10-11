import Foundation
import Combine

@MainActor
class SchedulerService: ObservableObject {
    @Published var config: ScheduleConfig {
        didSet { saveConfig() }
    }

    private var timer: Timer?
    private let defaults: UserDefaults
    private let configKey: String
    private var onTrigger: (() async -> Void)?

    init(defaults: UserDefaults = .standard, configKey: String = "MClean.ScheduleConfig") {
        self.defaults = defaults
        self.configKey = configKey
        if let data = defaults.data(forKey: configKey),
           var saved = try? JSONDecoder().decode(ScheduleConfig.self, from: data) {
            // A missed run is rescheduled from launch instead of firing
            // immediately. Keep genuinely future dates, even when only a few
            // seconds away, so relaunching does not postpone the schedule.
            if let next = saved.nextRunDate, next <= Date() {
                saved.nextRunDate = nil
            }
            self.config = saved
        } else {
            self.config = ScheduleConfig()
        }
    }

    func setTrigger(_ handler: @escaping () async -> Void) {
        self.onTrigger = handler
    }

    func start() {
        stop()
        guard config.isEnabled else { return }

        if config.nextRunDate == nil || config.nextRunDate! <= Date() {
            updateNextRunDate(from: Date())
        }

        let delay = max(1, config.nextRunDate?.timeIntervalSinceNow ?? config.interval.seconds)
        let scheduledTimer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkAndRun()
            }
        }
        scheduledTimer.tolerance = min(60, max(1, delay * 0.05))
        RunLoop.main.add(scheduledTimer, forMode: .common)
        timer = scheduledTimer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func updateSchedule(interval: ScheduleInterval) {
        config.interval = interval
        updateNextRunDate(from: Date())
        if config.isEnabled {
            start()
        }
    }

    func toggleEnabled(_ enabled: Bool) {
        config.isEnabled = enabled
        if enabled {
            start()
        } else {
            stop()
        }
    }

    // MARK: - Private

    private func checkAndRun() {
        guard config.isEnabled,
              let nextRun = config.nextRunDate,
              Date() >= nextRun else { return }

        config.lastRunDate = Date()
        updateNextRunDate(from: config.lastRunDate ?? Date())
        start()

        Task {
            await onTrigger?()
        }
    }

    private func updateNextRunDate(from base: Date) {
        config.nextRunDate = base.addingTimeInterval(config.interval.seconds)
    }

    private func saveConfig() {
        if let data = try? JSONEncoder().encode(config) {
            defaults.set(data, forKey: configKey)
        }
    }

}
