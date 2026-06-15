import Foundation

/// Maps `task.*` socket envelopes to/from the `AgentTask` record. Lives in the
/// app target (not `Models/Items`, which the smoke tool also compiles) because
/// it references `EventEnvelope`, which is app-only — keeping the record itself
/// smoke-clean (Foundation + GRDB).
extension AgentTask {
    /// Build a task from a `task.create` envelope, validating the
    /// trigger/cadence combination. Returns nil on an invalid payload so the
    /// handler can ack `{ok:false}`. Timestamps are placeholders — the store
    /// stamps `created_at`/`updated_at` on insert.
    init?(creationEnvelope e: EventEnvelope) {
        guard let name = e.detailValue("name", as: String.self), !name.isEmpty,
              let trigger = e.detailValue("trigger_type", as: String.self),
              let prompt = e.detailValue("prompt", as: String.self), !prompt.isEmpty
        else { return nil }

        let cadence = e.detailValue("cadence_kind", as: String.self)
        let interval = envelopeInt(e, "interval_seconds")
        let dailyTime = e.detailValue("daily_time", as: String.self)
        let runAt = envelopeDate(e, "run_at")
        let manualKey = e.detailValue("manual_key", as: String.self)
        let enabled = e.detailValue("enabled", as: Bool.self) ?? true

        guard AgentTask.isValidTrigger(
            trigger, cadence: cadence, intervalSeconds: interval, dailyTime: dailyTime
        ) else { return nil }

        let now = Date()
        self.init(
            id: UUIDv7.generate(), name: name, triggerType: trigger,
            cadenceKind: cadence, intervalSeconds: interval, dailyTime: dailyTime,
            runAt: runAt, manualKey: manualKey, prompt: prompt, enabled: enabled,
            lastRunAt: nil, createdAt: now, updatedAt: now)
    }

    /// Overlay the present fields of a `task.update` envelope onto this task and
    /// return the updated copy, or nil if the result is an invalid
    /// trigger/cadence combination. Only fields present in the envelope change;
    /// the CLI sends just what the user asked to change.
    func applyingUpdate(from e: EventEnvelope) -> AgentTask? {
        var t = self
        if let v = e.detailValue("name", as: String.self) { t.name = v }
        if let v = e.detailValue("trigger_type", as: String.self) { t.triggerType = v }
        if let v = e.detailValue("cadence_kind", as: String.self) { t.cadenceKind = v }
        if let v = envelopeInt(e, "interval_seconds") { t.intervalSeconds = v }
        if let v = e.detailValue("daily_time", as: String.self) { t.dailyTime = v }
        if let v = envelopeDate(e, "run_at") { t.runAt = v }
        if let v = e.detailValue("manual_key", as: String.self) { t.manualKey = v }
        if let v = e.detailValue("prompt", as: String.self), !v.isEmpty { t.prompt = v }
        if let v = e.detailValue("enabled", as: Bool.self) { t.enabled = v }

        guard AgentTask.isValidTrigger(
            t.triggerType, cadence: t.cadenceKind,
            intervalSeconds: t.intervalSeconds, dailyTime: t.dailyTime
        ) else { return nil }
        return t
    }

    /// A JSON-serializable dictionary for the `task.list` reply — the shape the
    /// agent reads to fuzzy-match a task by name. Dates are ISO-8601 strings.
    func replyDictionary() -> [String: Any] {
        var d: [String: Any] = [
            "id": id,
            "name": name,
            "trigger_type": triggerType,
            "prompt": prompt,
            "enabled": enabled,
        ]
        if let cadenceKind { d["cadence_kind"] = cadenceKind }
        if let intervalSeconds { d["interval_seconds"] = intervalSeconds }
        if let dailyTime { d["daily_time"] = dailyTime }
        if let runAt { d["run_at"] = Self.iso8601.string(from: runAt) }
        if let manualKey { d["manual_key"] = manualKey }
        if let lastRunAt { d["last_run_at"] = Self.iso8601.string(from: lastRunAt) }
        return d
    }

    /// Trigger/cadence validity, shared by create and update. recurring needs a
    /// cadence (interval → a positive interval; daily → an HH:MM time);
    /// one_shot and manual carry no required cadence fields.
    static func isValidTrigger(
        _ trigger: String, cadence: String?,
        intervalSeconds: Int?, dailyTime: String?
    ) -> Bool {
        switch trigger {
        case "recurring":
            switch cadence {
            case "interval": return (intervalSeconds ?? 0) > 0
            case "daily":
                return dailyTime?.range(
                    of: #"^\d{2}:\d{2}$"#, options: .regularExpression) != nil
            default: return false
            }
        case "one_shot", "manual":
            return true
        default:
            return false
        }
    }

    private static let iso8601 = ISO8601DateFormatter()
}

/// JSON numbers arrive via `AnyCodable` as `Int64` (or occasionally `Int`);
/// normalize either to `Int` for the record.
private func envelopeInt(_ e: EventEnvelope, _ key: String) -> Int? {
    if let v = e.detailValue(key, as: Int64.self) { return Int(v) }
    if let v = e.detailValue(key, as: Int.self) { return v }
    return nil
}

/// Parse an ISO-8601 datetime string (with or without fractional seconds).
/// Returns nil when absent or unparseable — a one-shot with no resolvable time
/// simply fires on the next tick.
private func envelopeDate(_ e: EventEnvelope, _ key: String) -> Date? {
    guard let s = e.detailValue(key, as: String.self) else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = fractional.date(from: s) { return d }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: s)
}
