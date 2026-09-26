import Foundation

/// Collects the timing of one request, from the trigger to the end of the spoken
/// answer, for a single readable report. Thread-safe and cheap: each call takes a
/// lock and appends a number, so it can be used from frame callbacks.
///
/// - Milestones (`mark`) are moments measured from `begin()`; only the first mark
///   of each name counts ("first face", not every face).
/// - Stages (`add`, `measure`) are repeated durations such as per-frame analysis,
///   summarized as count / average / max / total.
/// - Notes are labels shown in the header (trigger kind, outcome).
///
/// Components take it as an optional; nil (the default) records nothing.
public final class LatencyRecorder: @unchecked Sendable {
  private let clock = ContinuousClock()
  private let lock = NSLock()
  private var start: ContinuousClock.Instant?
  private var milestones: [(name: String, at: Duration)] = []
  private var stages: [String: [Duration]] = [:]
  private var stageOrder: [String] = []
  private var notes: [(key: String, value: String)] = []
  private var requests = 0

  public init() {}

  /// Starts a new request, discarding the previous one's timings.
  public func begin() {
    lock.withLock {
      requests += 1
      start = clock.now
      milestones = []
      stages = [:]
      stageOrder = []
      notes = []
    }
  }

  /// Records the first time `name` happens in this request.
  public func mark(_ name: String) {
    let now = clock.now
    lock.withLock {
      guard let start, !milestones.contains(where: { $0.name == name }) else { return }
      milestones.append((name, now - start))
    }
  }

  /// Adds one sample of a repeated stage.
  public func add(_ stage: String, _ duration: Duration) {
    lock.withLock {
      guard start != nil else { return }
      if stages[stage] == nil { stageOrder.append(stage) }
      stages[stage, default: []].append(duration)
    }
  }

  /// Times `body` as one sample of `stage`.
  public func measure<T>(_ stage: String, _ body: () throws -> T) rethrows -> T {
    let began = clock.now
    defer { add(stage, clock.now - began) }
    return try body()
  }

  /// Sets a header label, replacing an earlier value for the same key.
  public func note(_ key: String, _ value: String) {
    lock.withLock {
      guard start != nil else { return }
      notes.removeAll { $0.key == key }
      notes.append((key, value))
    }
  }

  /// The current request as console lines, each starting with `prefix` so the
  /// Xcode console filter can show only these.
  public func report(prefix: String = "[Latency]") -> String {
    lock.withLock {
      var lines: [String] = []
      let header = (["Request #\(requests)"] + notes.map { "\($0.key): \($0.value)" }).joined(separator: " · ")
      lines.append("── \(header) ──")
      lines.append("Timeline (since trigger)")
      for (name, at) in milestones.sorted(by: { $0.at < $1.at }) {
        lines.append("  " + Self.pad(Self.format(at), 9, left: true) + "  " + name)
      }
      if !stageOrder.isEmpty {
        let width = max(24, stageOrder.map(\.count).max() ?? 0)
        lines.append("Stages" + String(repeating: " ", count: width - 4) + "   n      avg      max    total")
        for stage in stageOrder {
          let samples = stages[stage] ?? []
          let total = samples.reduce(.zero, +)
          let average = samples.isEmpty ? .zero : total / samples.count
          let maximum = samples.max() ?? .zero
          lines.append(
            "  " + Self.pad(stage, width) + Self.pad("\(samples.count)", 4, left: true)
              + Self.pad(Self.format(average), 9, left: true) + Self.pad(Self.format(maximum), 9, left: true)
              + Self.pad(Self.format(total), 9, left: true))
        }
      }
      return lines.map { "\(prefix) \($0)" }.joined(separator: "\n")
    }
  }

  /// Milliseconds under a second, seconds above.
  static func format(_ duration: Duration) -> String {
    let c = duration.components
    let seconds = Double(c.seconds) + Double(c.attoseconds) / 1e18
    return seconds < 1
      ? String(format: "%.1fms", seconds * 1000)
      : String(format: "%.2fs", seconds)
  }

  private static func pad(_ text: String, _ width: Int, left: Bool = false) -> String {
    let fill = String(repeating: " ", count: max(0, width - text.count))
    return left ? fill + text : text + fill
  }
}
