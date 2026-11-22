import Foundation

/// How far back an activity list looks. Backed by the connection rows the
/// helper has already stored, so this is a filter over the audit trail, not a
/// separate query.
///
/// Shared by the full audit window and the menu-bar mini tabs (AI + Misc) so
/// the same 1h/6h/24h/All dropdown can't drift between surfaces.
enum ActivityTimeWindow: String, CaseIterable, Identifiable {
    case hour = "1h"
    case sixHours = "6h"
    case day = "24h"
    case all = "All"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hour: return "Past hour"
        case .sixHours: return "Past 6 hours"
        case .day: return "Past 24 hours"
        case .all: return "All time"
        }
    }

    var cutoff: Date? {
        switch self {
        case .hour: return Date().addingTimeInterval(-3_600)
        case .sixHours: return Date().addingTimeInterval(-6 * 3_600)
        case .day: return Date().addingTimeInterval(-24 * 3_600)
        case .all: return nil
        }
    }
}
