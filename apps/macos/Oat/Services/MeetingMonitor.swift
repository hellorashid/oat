import EventKit
import Foundation

struct DetectedMeeting: Equatable, Sendable {
    var title: String
    var startsAt: Date
}

@MainActor
final class MeetingMonitor {
    private let eventStore = EKEventStore()
    private var promptedEventIds: Set<String> = []
    private var task: Task<Void, Never>?

    func requestAccess() async -> Bool {
        if Permissions.calendarState() == .granted {
            return true
        }
        guard EKEventStore.authorizationStatus(for: .event) == .notDetermined else {
            return false
        }
        return await withCheckedContinuation { continuation in
            eventStore.requestFullAccessToEvents { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    func start(onMeeting: @escaping @MainActor (DetectedMeeting) -> Void) {
        guard task == nil else { return }
        task = Task { [weak self] in
            while let self, !Task.isCancelled {
                if Permissions.calendarState() == .granted, let meeting = self.detectMeeting() {
                    onMeeting(meeting)
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func detectMeeting(now: Date = Date()) -> DetectedMeeting? {
        let soon = now.addingTimeInterval(60)
        let predicate = eventStore.predicateForEvents(
            withStart: now,
            end: soon,
            calendars: nil
        )
        let event = eventStore.events(matching: predicate)
            .filter { event in
                !event.isAllDay
                    && event.status != .canceled
                    && event.endDate > now
                    && event.startDate <= soon
                    && event.attendees?.contains(where: { $0.isCurrentUser && $0.participantStatus == .declined }) != true
            }
            .sorted { $0.startDate < $1.startDate }
            .first { event in
                !promptedEventIds.contains(identifier(for: event))
            }

        guard let event else { return nil }
        promptedEventIds.insert(identifier(for: event))
        let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return DetectedMeeting(
            title: title.flatMap { $0.isEmpty ? nil : $0 } ?? "Calendar meeting",
            startsAt: event.startDate
        )
    }

    private func identifier(for event: EKEvent) -> String {
        "\(event.calendarItemIdentifier)|\(event.startDate.timeIntervalSinceReferenceDate)"
    }
}
