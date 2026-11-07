import Foundation

/// Minimal RFC 5545 writer for portable calendar/reminder exports.
enum ICSWriter {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    static func utc(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: d)
    }

    static func dateOnly(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd"
        return f.string(from: d)
    }

    /// Lines longer than 75 octets are folded with CRLF + space.
    static func fold(_ line: String) -> String {
        var out = ""
        var current = ""
        for ch in line {
            if (current + String(ch)).utf8.count > 75 {
                out += current + "\r\n "
                current = ""
            }
            current.append(ch)
        }
        return out + current
    }

    static func wrap(_ body: [String]) -> String {
        (["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//iCloud IPA//Backup//EN", "CALSCALE:GREGORIAN"] + body + ["END:VCALENDAR"])
            .map(fold).joined(separator: "\r\n") + "\r\n"
    }

    static func events(_ events: [CalendarEventDTO], stamp: Date = Date()) -> String {
        var lines: [String] = []
        for e in events {
            lines.append("BEGIN:VEVENT")
            lines.append("UID:\(escape(e.identifier))@icloudipa")
            lines.append("DTSTAMP:\(utc(stamp))")
            if e.allDay {
                lines.append("DTSTART;VALUE=DATE:\(dateOnly(e.start))")
                lines.append("DTEND;VALUE=DATE:\(dateOnly(e.end.addingTimeInterval(1)))")
            } else {
                lines.append("DTSTART:\(utc(e.start))")
                lines.append("DTEND:\(utc(e.end))")
            }
            lines.append("SUMMARY:\(escape(e.title))")
            if let l = e.location, !l.isEmpty { lines.append("LOCATION:\(escape(l))") }
            if let n = e.notes, !n.isEmpty { lines.append("DESCRIPTION:\(escape(n))") }
            if let u = e.url, !u.isEmpty { lines.append("URL:\(u)") }
            if !e.calendarTitle.isEmpty { lines.append("CATEGORIES:\(escape(e.calendarTitle))") }
            lines.append("END:VEVENT")
        }
        return wrap(lines)
    }

    static func todos(_ items: [ReminderDTO], stamp: Date = Date()) -> String {
        var lines: [String] = []
        for r in items {
            lines.append("BEGIN:VTODO")
            lines.append("UID:\(escape(r.identifier))@icloudipa")
            lines.append("DTSTAMP:\(utc(stamp))")
            lines.append("SUMMARY:\(escape(r.title))")
            if let n = r.notes, !n.isEmpty { lines.append("DESCRIPTION:\(escape(n))") }
            if let d = r.dueDate { lines.append("DUE:\(utc(d))") }
            if r.priority > 0 { lines.append("PRIORITY:\(r.priority)") }
            lines.append("STATUS:\(r.completed ? "COMPLETED" : "NEEDS-ACTION")")
            if let c = r.completionDate { lines.append("COMPLETED:\(utc(c))") }
            if !r.listTitle.isEmpty { lines.append("CATEGORIES:\(escape(r.listTitle))") }
            lines.append("END:VTODO")
        }
        return wrap(lines)
    }
}
