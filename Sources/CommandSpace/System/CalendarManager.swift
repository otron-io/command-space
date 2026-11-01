//
//  CalendarManager.swift
//  Command Space
//
//  Today's and tomorrow's calendar events, for meeting nudges and suggestions.
//

import EventKit
import Foundation

struct EventModel: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String?
    let notes: String?
    let url: URL?
    let participants: [String]
}

@MainActor
final class CalendarManager: ObservableObject {
    static let shared = CalendarManager()

    @Published private(set) var events: [EventModel] = []

    private let store = EKEventStore()
    private var timer: Timer?

    private init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            Task { @MainActor in CalendarManager.shared.reload() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in CalendarManager.shared.reload() }
        }
        reload()
    }

    func reload() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            events = []
            return
        }
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 2, to: start)!
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                EventModel(
                    id: event.calendarItemIdentifier + "@" + String(event.startDate.timeIntervalSince1970),
                    title: event.title ?? "Untitled",
                    start: event.startDate,
                    end: event.endDate,
                    isAllDay: event.isAllDay,
                    location: event.location,
                    notes: event.notes,
                    url: event.url,
                    participants: (event.attendees ?? []).compactMap { $0.name ?? $0.url.absoluteString }
                )
            }
    }
}
