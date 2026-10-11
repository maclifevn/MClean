import Foundation

enum CleanupSizeFilter: String, CaseIterable, Identifiable {
    case any = "Any size"
    case megabytes100 = "Over 100 MB"
    case gigabyte1 = "Over 1 GB"
    case gigabytes10 = "Over 10 GB"

    var id: String { rawValue }

    var minimumBytes: Int64 {
        switch self {
        case .any: return 0
        case .megabytes100: return 100_000_000
        case .gigabyte1: return 1_000_000_000
        case .gigabytes10: return 10_000_000_000
        }
    }
}

enum CleanupAgeFilter: String, CaseIterable, Identifiable {
    case any = "Any age"
    case month = "Older than 30 days"
    case sixMonths = "Older than 6 months"
    case year = "Older than a year"

    var id: String { rawValue }

    func cutoff(relativeTo now: Date) -> Date? {
        switch self {
        case .any: return nil
        case .month: return Calendar.current.date(byAdding: .day, value: -30, to: now)
        case .sixMonths: return Calendar.current.date(byAdding: .month, value: -6, to: now)
        case .year: return Calendar.current.date(byAdding: .year, value: -1, to: now)
        }
    }
}

enum CleanupSortOrder: String, CaseIterable, Identifiable {
    case largest = "Largest first"
    case smallest = "Smallest first"
    case oldest = "Oldest first"
    case name = "Name"

    var id: String { rawValue }
}

struct CleanupReviewFilter {
    var query = ""
    var size: CleanupSizeFilter = .any
    var age: CleanupAgeFilter = .any
    var order: CleanupSortOrder = .largest

    func apply(to items: [CleanableItem], now: Date = Date()) -> [CleanableItem] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let cutoff = age.cutoff(relativeTo: now)
        return items.filter { item in
            guard item.size >= size.minimumBytes else { return false }
            if let cutoff {
                guard let modified = item.lastModified, modified < cutoff else { return false }
            }
            return search.isEmpty || item.name.localizedCaseInsensitiveContains(search)
                || item.path.localizedCaseInsensitiveContains(search)
        }.sorted { left, right in
            switch order {
            case .largest where left.size != right.size: return left.size > right.size
            case .smallest where left.size != right.size: return left.size < right.size
            case .oldest where left.lastModified != right.lastModified:
                return (left.lastModified ?? .distantFuture) < (right.lastModified ?? .distantFuture)
            default:
                let comparison = left.name.localizedStandardCompare(right.name)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return left.path < right.path
            }
        }
    }
}
