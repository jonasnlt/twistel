import AppKit
import SwiftUI

/// Progress and result at the top of the screen where the files were dropped, below the notch (without one: top centre).
/// While work runs: a pill with what it does, the step ("Page 3 of 12") and a bar, after a quiet first second. When all of it is over:
/// a card with the result, Open, Show in Finder and Undo; it goes after 5 s (not while the pointer is on it: after the pointer leaves,
/// 5 s anew), stays after an error until closed, and says "Cancelled" briefly when the work was cancelled. While VoiceOver runs it
/// never goes by itself (HIG: no time limits for reading).
@MainActor
final class NotchHUD {
    private weak var runner: JobRunner?
    private var panel: NotchPanel?
    private var showWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var announced: Set<UUID> = []
    /// Counts fades in and out; a fade out that was overtaken by showing again leaves the panel on screen.
    private var fading = 0
    var hovering = false {
        didSet { if !hovering { scheduleAutoHide() } else { hideWork?.cancel() } }
    }

    init(runner: JobRunner) {
        self.runner = runner
    }

    func update() {
        guard let runner else { return }
        let jobs = runner.jobs
        guard !jobs.isEmpty else { return hide() }
        if jobs.allSatisfy({ $0.status.isFinished }) {
            showWork?.cancel()
            showWork = nil
            show()
            announce(jobs)
            scheduleAutoHide()
        } else {
            hideWork?.cancel()
            if panel?.isVisible == true {
                place()
            } else if showWork == nil {
                // Work that is over within about a second shows no bar, only the card at the end.
                let work = DispatchWorkItem { [weak self] in
                    self?.showWork = nil
                    guard let self, let runner = self.runner, runner.jobs.contains(where: { !$0.status.isFinished }) else { return }
                    self.show()
                }
                showWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + ProgressDisplay.quiet, execute: work)
            }
        }
    }

    /// How long the card stays: errors and notes until closed, "Cancelled" briefly, a result 5 seconds; with VoiceOver until closed.
    nonisolated static func cardSeconds(for jobs: [Job], voiceOver: Bool = false) -> TimeInterval? {
        if voiceOver { return nil }
        let failed = jobs.contains { if case .failed = $0.status { return true } else { return false } }
        if failed || jobs.contains(where: { $0.note != nil && $0.status == .done }) { return nil }
        if jobs.allSatisfy({ $0.status == .cancelled }) { return 2.5 }
        return 5
    }

    private func scheduleAutoHide() {
        hideWork?.cancel()
        guard let runner, !hovering, !runner.jobs.isEmpty, runner.jobs.allSatisfy({ $0.status.isFinished }),
              let seconds = Self.cardSeconds(for: runner.jobs, voiceOver: NSWorkspace.shared.isVoiceOverEnabled) else { return }
        let work = DispatchWorkItem { [weak self] in self?.close() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// The card's close button, or its time is up: the batch is over.
    func close() {
        hideWork?.cancel()
        runner?.dismissAll()
    }

    func closeLater(_ seconds: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.close() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func show() {
        guard let runner else { return }
        if panel == nil { panel = NotchPanel(rootView: NotchHUDView(runner: runner, hud: self)) }
        place()
        guard let panel else { return }
        fading += 1
        if !panel.isVisible || panel.alphaValue < 1 {
            // Fades in; the pill and card themselves change with a cross-fade (`NotchHUDView`).
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        showWork?.cancel()
        showWork = nil
        hideWork?.cancel()
        hovering = false
        fading += 1
        let token = fading
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard self?.fading == token else { return }
            panel.orderOut(nil)
        })
    }

    /// Below the menu bar of the screen with the files, centred on the notch when there is one.
    private func place() {
        guard let panel else { return }
        let point = runner?.presentationPoint ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        panel.layoutContent()
        let size = panel.fittingSize
        panel.setFrame(Self.frame(for: size, on: screen.frame, visible: screen.visibleFrame, notchLeft: screen.auxiliaryTopLeftArea,
                                  notchRight: screen.auxiliaryTopRightArea), display: true)
    }

    /// Centred below the notch (between the two areas beside it) or the middle of the screen, just under the menu bar.
    nonisolated static func frame(for size: CGSize, on frame: CGRect, visible: CGRect, notchLeft: CGRect?, notchRight: CGRect?) -> CGRect {
        var centerX = frame.midX
        if let left = notchLeft, let right = notchRight { centerX = (left.maxX + right.minX) / 2 }
        let x = min(max(frame.minX + 8, (centerX - size.width / 2).rounded()), frame.maxX - size.width - 8)
        return CGRect(x: x, y: visible.maxY - size.height - 6, width: size.width, height: size.height)
    }

    /// VoiceOver says how it went, without moving the focus.
    private func announce(_ jobs: [Job]) {
        let new = jobs.filter { !announced.contains($0.id) }
        guard !new.isEmpty else { return }
        new.forEach { announced.insert($0.id) }
        // One sound for the batch, with the card that shows the same (not everyone hears it).
        SoundPlayer.shared.play(SoundPlayer.event(for: ResultCardModel(jobs: jobs)))
        let text = ResultCardModel(jobs: jobs).headline
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

final class NotchPanel: NSPanel {
    private let hosting: NSHostingView<AnyView>

    init<V: View>(rootView: V) {
        hosting = NSHostingView(rootView: AnyView(rootView))
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 60), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hosting.sizingOptions = [.intrinsicContentSize]
        contentView = hosting
    }

    override var canBecomeKey: Bool { true }

    var fittingSize: CGSize { hosting.fittingSize }
    func layoutContent() { hosting.layoutSubtreeIfNeeded() }
}

/// What the card says about a finished batch.
struct ResultCardModel {
    let jobs: [Job]

    var done: [Job] { jobs.filter { $0.status == .done } }
    var failed: [(job: Job, message: String)] { jobs.compactMap { job in if case .failed(let message) = job.status { return (job, message) } else { return nil } } }
    var cancelled: Bool { jobs.allSatisfy { $0.status == .cancelled } }
    var outputs: [URL] { done.flatMap(\.outputs) }
    var canUndo: Bool { done.contains { $0.undoable && !$0.outputs.isEmpty } }

    var headline: String {
        if cancelled { return tr("Canceled", "Abgebrochen") }
        if jobs.count == 1 {
            if let failure = failed.first { return failure.job.title + ": " + tr("failed", "fehlgeschlagen") }
            return outputs.count == 1 ? outputs[0].lastPathComponent : (outputs.isEmpty ? jobs[0].title : tr("\(outputs.count) files made", "\(outputs.count) Dateien erstellt"))
        }
        if failed.isEmpty { return tr("\(done.count) files done", "\(done.count) Dateien fertig") }
        return tr("\(done.count) of \(jobs.count) done, \(failed.count) failed", "\(done.count) von \(jobs.count) fertig, \(failed.count) fehlgeschlagen")
    }

    /// Before and after, for compressing one file.
    var sizes: String? {
        guard jobs.count == 1, let job = done.first, job.reportsSizes, let input = job.inputs.first, let output = job.outputs.first else { return nil }
        return SizeChange.text(before: FileSizeFormatter.size(of: input), after: FileSizeFormatter.size(of: output))
    }
}

struct NotchHUDView: View {
    @ObservedObject var runner: JobRunner
    let hud: NotchHUD
    var style: RingStyle = .glass
    @State private var undoMessage: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let jobs = runner.jobs
        Group {
            if !jobs.isEmpty, jobs.allSatisfy({ $0.status.isFinished }) {
                ResultCard(model: ResultCardModel(jobs: jobs), undoMessage: undoMessage, close: hud.close, undo: undo,
                           glass: (style == .glass ? RingStyle.currentHUD : style) == .glass)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            } else if !jobs.isEmpty {
                ProgressPill(jobs: jobs, cancel: { runner.cancelAll() })
                    .transition(.opacity)
            }
        }
        .padding(8)
        .modifier(HUDSurface(style: style == .glass ? RingStyle.currentHUD : style))
        .padding(6)
        .onHover { hud.hovering = $0 }
        // The app is in the background while the pill shows; the bar keeps the colour of an active window.
        .environment(\.appearsActive, true)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: jobs.allSatisfy { $0.status.isFinished })
        .onChange(of: jobs.map(\.id)) { _, _ in undoMessage = nil }
    }

    private func undo() {
        let result = runner.undo(runner.jobs)
        // The Finder's trash sound only when it really worked; otherwise the error sound, with the message below.
        if let sound = SoundPlayer.event(forUndo: result.trashed, left: result.left) { SoundPlayer.shared.play(sound) }
        if result.left.isEmpty {
            undoMessage = tr("Moved to the Trash", "In den Papierkorb gelegt")
        } else if result.trashed.isEmpty {
            undoMessage = tr("Nothing was moved to the Trash: the result was changed or moved since.", "Nichts in den Papierkorb gelegt: Das Ergebnis wurde inzwischen verändert oder verschoben.")
        } else {
            undoMessage = tr("\(result.trashed.count) moved to the Trash, \(result.left.count) left as they were.", "\(result.trashed.count) in den Papierkorb gelegt, \(result.left.count) blieben, wie sie waren.")
        }
        hud.closeLater(2.5)
    }
}

extension RingStyle {
    @MainActor
    static var currentHUD: RingStyle { current }
}

struct HUDSurface: ViewModifier {
    let style: RingStyle

    func body(content: Content) -> some View {
        switch style {
        case .glass:
            // Dimmed behind the text, so writing on the desktop doesn't show through the glass.
            content
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(nsColor: .windowBackgroundColor).opacity(RadialWheelView.textDimming)))
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        case .solid(let strong):
            content
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(strong ? Color.primary : Color(nsColor: .separatorColor), lineWidth: strong ? 1.5 : 1))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
    }
}

/// The pill while work runs: what it does, the step, a bar or a running stripe, and Cancel.
struct ProgressPill: View {
    let jobs: [Job]
    let cancel: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let now = context.date
            let running = jobs.first { $0.status == .running } ?? jobs.first { !$0.status.isFinished } ?? jobs[0]
            let finishedCount = jobs.filter(\.status.isFinished).count
            HStack(spacing: 10) {
                Image(systemName: running.symbol)
                    .font(.system(size: 15))
                    .frame(width: 22)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(running.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(secondLine(running, finished: finishedCount))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    bar(now: now)
                        .frame(height: 6)
                }
                .frame(width: 230, alignment: .leading)
                Button(action: cancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tr("Cancel", "Abbrechen"))
                .accessibilityLabel(tr("Cancel", "Abbrechen"))
            }
            .padding(.horizontal, 6)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(running.title + ", " + secondLine(running, finished: finishedCount))
        }
    }

    private func secondLine(_ job: Job, finished: Int) -> String {
        var parts: [String] = []
        if jobs.count > 1 { parts.append(tr("\(finished) of \(jobs.count) done", "\(finished) von \(jobs.count) fertig")) }
        else { parts.append(job.detail) }
        if job.status == .waiting { parts.append(tr("Waiting", "Wartet")) }
        if let step = job.step { parts.append(step) }
        return parts.joined(separator: " · ")
    }

    /// One bar for all: the average of the jobs (finished ones count as full).
    @ViewBuilder private func bar(now: Date) -> some View {
        let started = jobs.compactMap(\.startedAt).min() ?? now
        let progress = jobs.map { $0.status.isFinished ? 1 : $0.progress }.reduce(0, +) / Double(max(jobs.count, 1))
        let lastReport = jobs.filter { $0.status == .running }.map(\.lastReportAt).max() ?? now
        switch ProgressDisplay.bar(elapsed: now.timeIntervalSince(started), progress: progress, sinceLastReport: now.timeIntervalSince(lastReport)) {
        case .none:
            Color.clear
        case .indeterminate:
            RunningLight(track: Color.primary.opacity(contrast == .increased ? 0.3 : 0.12))
                .frame(height: 5)
                .accessibilityElement()
                .accessibilityLabel(tr("Working", "Wird bearbeitet"))
        case .determinate(let value):
            // Drawn here: the system bar ignores the app's colour on macOS. Same size and behaviour, emerald on a quiet track.
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(contrast == .increased ? 0.3 : 0.12))
                    Capsule().fill(Theme.accentForeground).frame(width: max(5, proxy.size.width * min(1, max(0, value))))
                }
            }
            .frame(height: 5)
            .animation(.linear(duration: 0.3), value: value)
            .accessibilityElement()
            .accessibilityLabel(tr("Progress", "Fortschritt"))
            .accessibilityValue("\(Int((value * 100).rounded())) %")
        }
    }
}

/// Work without a known amount: an emerald light that runs to and fro on the bar's track (the system's running bar is grey in a
/// window that isn't the active one, and twistel's pill never is). With "Reduce motion" it stands still across the track and only
/// pulses slowly.
struct RunningLight: View {
    let track: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One way across in this long; the light is this part of the track.
    nonisolated static let period: TimeInterval = 1.4
    nonisolated static let share: CGFloat = 0.3
    /// "Reduce motion": one slow breath in this long, between these brightnesses.
    nonisolated static let pulsePeriod: TimeInterval = 2.4
    nonisolated static let pulseRange: ClosedRange<Double> = 0.35...0.9

    /// Where the light's left edge is, as a part of the free track (0 left, 1 right): there and back, easing at both ends.
    nonisolated static func position(at time: TimeInterval) -> CGFloat {
        let phase = time.truncatingRemainder(dividingBy: 2 * period) / period
        let way = phase <= 1 ? phase : 2 - phase
        return CGFloat((1 - cos(way * .pi)) / 2)
    }

    /// The brightness of the still light with "Reduce motion".
    nonisolated static func pulse(at time: TimeInterval) -> Double {
        let wave = (1 - cos(time / pulsePeriod * 2 * .pi)) / 2
        return pulseRange.lowerBound + (pulseRange.upperBound - pulseRange.lowerBound) * wave
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 / 15 : nil)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(track)
                    if reduceMotion {
                        Capsule().fill(Theme.accentForeground).opacity(Self.pulse(at: time))
                    } else {
                        let width = proxy.size.width * Self.share
                        Capsule().fill(Theme.accentForeground)
                            .frame(width: width)
                            .offset(x: (proxy.size.width - width) * Self.position(at: time))
                    }
                }
            }
        }
    }
}

/// The card when all work is over.
struct ResultCard: View {
    let model: ResultCardModel
    let undoMessage: String?
    let close: () -> Void
    let undo: () -> Void
    /// On glass the other buttons are glass, otherwise bordered; the main one is emerald either way (design rule: colour only for
    /// the main action).
    var glass = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.headline)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    if let sizes = model.sizes {
                        Text(sizes).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    ForEach(Array(model.failed.prefix(3).enumerated()), id: \.offset) { _, failure in
                        Text(model.jobs.count > 1 ? "\(failure.job.detail): \(failure.message)" : failure.message)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(model.done.compactMap(\.note).prefix(2), id: \.self) { note in
                        // In the text colour: orange text on glass is too faint (about 2.2 : 1); the orange is the triangle above.
                        Text(note).font(.system(size: 11)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let undoMessage {
                        Text(undoMessage).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tr("Close", "Schließen"))
                .accessibilityLabel(tr("Close", "Schließen"))
                .keyboardShortcut(.cancelAction)
            }
            if !model.outputs.isEmpty, undoMessage == nil {
                HStack(spacing: 8) {
                    if model.outputs.count == 1 {
                        main(Button(tr("Open", "Öffnen")) { NSWorkspace.shared.open(model.outputs[0]) })
                        secondary(Button(tr("Show in Finder", "Im Finder zeigen")) { NSWorkspace.shared.activateFileViewerSelecting(model.outputs) })
                    } else {
                        main(Button(tr("Show in Finder", "Im Finder zeigen")) { NSWorkspace.shared.activateFileViewerSelecting(model.outputs) })
                    }
                    if model.canUndo {
                        secondary(Button(tr("Undo", "Rückgängig"), action: undo))
                            .help(tr("Moves what was just made to the Trash. The original stays.", "Legt das gerade Erstellte in den Papierkorb. Das Original bleibt."))
                    }
                }
                .controlSize(.small)
                .padding(.leading, 28)
            }
        }
        .frame(width: 320, alignment: .leading)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .contain)
    }

    /// Always emerald: the card is never the active window, and system buttons grey their colour out there.
    private func main(_ button: Button<Text>) -> some View {
        button.buttonStyle(AccentButtonStyle())
    }

    @ViewBuilder private func secondary(_ button: Button<Text>) -> some View {
        if glass { button.buttonStyle(.glass) } else { button.buttonStyle(.bordered) }
    }

    /// An error has its own shape (an octagon with ×), not only its colour.
    private var symbol: String {
        if model.cancelled { return "xmark.circle" }
        if !model.failed.isEmpty { return "xmark.octagon.fill" }
        if model.done.contains(where: { $0.note != nil }) { return "exclamationmark.triangle.fill" }
        return "checkmark.circle.fill"
    }

    private var tint: Color {
        if model.cancelled { return .secondary }
        if !model.failed.isEmpty { return .red }
        if model.done.contains(where: { $0.note != nil }) { return .orange }
        return Theme.accentForeground
    }
}
