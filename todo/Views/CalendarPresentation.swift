import EventKit
import SwiftUI
enum CalendarPresentation {
    static func color(forCalendarID id: String) -> Color {
        if let calendar = CalendarService.shared.ekCalendar(withIdentifier: id) {
            return Color(cgColor: calendar.cgColor)
        }
        return .accentColor
    }
}
