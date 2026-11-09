import AppKit

/// Scrolling over an open ring changes the ring: one step of a mouse wheel, or one swipe on a Magic Mouse, is one ring.
/// Down (or right) is the next ring, up (or left) the one before, whatever the Mac's scrolling direction is set to. Shift turns a
/// wheel into sideways scrolling (macOS does that), so both directions count.
///
/// What arrives differs. A plain wheel sends one event per step. A wheel with smooth scrolling, and every wheel during a file drag,
/// sends each step as a short burst of events that grows and dies away (measured during a Finder drag: 7, 11, 4, 3 … 1 points over a
/// quarter of a second), without the gesture phases a trackpad or Magic Mouse sends otherwise. Such a burst is one step; a new one
/// begins after a pause or when the amount jumps up again (a second step while the first is still dying away).
struct ScrollStepper {
    struct Event {
        var deltaX: Double
        var deltaY: Double
        /// Points (smooth scrolling, Magic Mouse, trackpad) rather than lines (a plain wheel).
        var precise: Bool
        /// The gesture of a Magic Mouse or trackpad (began, changed, ended); none for a wheel.
        var phase: NSEvent.Phase
        /// Scrolling that goes on by itself after the fingers left: never counted.
        var momentum: NSEvent.Phase
        /// The Mac's "natural" scrolling: the numbers are the other way round.
        var inverted: Bool
        var time: TimeInterval
    }

    /// Points a burst or a swipe must add up to before it counts (a hand resting on a Magic Mouse sends a point or two).
    static let burstThreshold = 3.0
    static let swipeThreshold = 12.0
    /// A pause longer than this starts a new step.
    static let pause: TimeInterval = 0.12

    private var total = 0.0
    private var fired = false
    private var lastAmount = 0.0
    private var lastTime: TimeInterval = -1
    private var lastDirection = 0

    /// +1 next ring, -1 the one before, 0 nothing (yet).
    mutating func step(_ event: Event) -> Int {
        guard event.momentum == [] else { return 0 }
        var value = abs(event.deltaY) >= abs(event.deltaX) ? event.deltaY : event.deltaX
        if event.inverted { value = -value }
        // Down and right are negative here: the next ring.
        let direction = value < 0 ? 1 : (value > 0 ? -1 : 0)
        let amount = abs(value)
        defer { lastTime = event.time }

        if !event.precise {
            // A plain wheel: every event is a step.
            return direction
        }
        if event.phase != [] {
            // A swipe on a Magic Mouse or trackpad: once per gesture.
            if event.phase.contains(.began) || event.phase.contains(.mayBegin) { total = 0; fired = false }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) { total = 0; fired = false; return 0 }
            guard direction != 0 else { return 0 }
            total += value
            guard !fired, abs(total) >= Self.swipeThreshold else { return 0 }
            fired = true
            return total < 0 ? 1 : -1
        }
        // A burst without phases (smooth wheel, or any wheel during a drag).
        guard direction != 0 else { return 0 }
        let paused = lastTime < 0 || event.time - lastTime > Self.pause
        let jumped = amount >= 4 && amount >= 2 * lastAmount
        if paused || jumped || direction != lastDirection {
            total = 0
            fired = false
        }
        lastAmount = amount
        lastDirection = direction
        total += amount
        guard !fired, total >= Self.burstThreshold else { return 0 }
        fired = true
        return direction
    }
}

extension ScrollStepper.Event {
    init(_ event: NSEvent) {
        self.init(deltaX: Double(event.scrollingDeltaX), deltaY: Double(event.scrollingDeltaY), precise: event.hasPreciseScrollingDeltas,
                  phase: event.phase, momentum: event.momentumPhase, inverted: event.isDirectionInvertedFromDevice, time: event.timestamp)
    }
}
