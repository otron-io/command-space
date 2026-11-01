//
//  SpaceMark.swift
//  Command Space
//
//  Space's mark: a living space bar. A wide key cap with eyes and a mouth, drawn as vector
//  shapes so it stays crisp from menu-bar size to the app icon.
//
//  It shows a mood (what's going on) and, when `reactive`, reacts to moments as they happen:
//  keystrokes make it hop and look at your text, Snap 1's decisions make its eyes pop, sending
//  winds it up and launches it, results make it happy, errors make it shake. Between moments
//  it follows the pointer, glances around and blinks. Moods blend into each other rather than
//  snapping. Everything is a pure function of time plus a few timestamps, so it costs nothing
//  when off screen.
//

import AppKit
import SwiftUI

enum SpaceMood: Equatable {
    case idle        // blinks, glances around, follows the pointer
    case thinking    // eyes circle, deciding
    case working     // focused squint at the work, little bob
    case attention   // wide eyes, bouncing, needs you
    case listening   // round eyes and body that swell with your voice
    case happy       // ^ ^ and a smile
    case offline     // dozing
}

// MARK: - Moments

/// Moments the mark reacts to. Anything can report one; reactive marks pick it up next frame.
@MainActor
enum SpaceMarkEvents {
    enum Kind: CaseIterable { case keystroke, decided, send, success, error, attention }

    private(set) static var last: [Kind: TimeInterval] = [:]
    /// How much was typed (eyes drift toward the end of the text as it grows).
    private(set) static var typedLength = 0

    static func fire(_ kind: Kind) {
        last[kind] = Date.timeIntervalSinceReferenceDate
    }

    static func typed(length: Int) {
        typedLength = length
        fire(.keystroke)
    }

    /// Seconds since `kind` last happened (∞ if never).
    static func age(_ kind: Kind, now: TimeInterval) -> Double {
        last[kind].map { now - $0 } ?? .infinity
    }

    // Pointer tracking (polled while drawing; no event monitors needed).
    private static var pointer = NSEvent.mouseLocation
    private static var pointerMovedAt: TimeInterval = 0

    static func pointerSample(now: TimeInterval) -> (point: CGPoint, idle: Double) {
        let current = NSEvent.mouseLocation
        if hypot(current.x - pointer.x, current.y - pointer.y) > 1.5 {
            pointer = current
            pointerMovedAt = now
        }
        return (pointer, now - pointerMovedAt)
    }
}

// MARK: - Shapes

/// The key cap: a wide, soft rounded rectangle.
struct SpaceKeyShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: min(rect.height * 0.42, rect.width * 0.3), style: .continuous)
    }
}

/// "^" for happy eyes.
private struct HappyEye: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.6))
        return p
    }
}

/// A smile, or (negative curve) a frown.
private struct MouthArc: Shape {
    var curve: CGFloat
    var animatableData: CGFloat {
        get { curve }
        set { curve = newValue }
    }
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY), control: CGPoint(x: rect.midX, y: rect.midY + rect.height * curve))
        return p
    }
}

// MARK: - Pose

/// Everything that describes one frame. Moods produce poses; poses blend.
private struct Pose {
    enum Eye { case open, happy, cross }
    enum Mouth { case none, smile, o, flat, frown }

    var eyeW: CGFloat = 0.11      // fractions of the width
    var eyeH: CGFloat = 0.34      // fractions of the height
    var lid: CGFloat = 0          // 0 open … 1 closed (from the top)
    var eye: Eye = .open
    var mouth: Mouth = .none
    var mouthSize: CGFloat = 1
    var gaze = CGPoint.zero       // -1…1
    var hop: CGFloat = 0          // fraction of height, up
    var squashX: CGFloat = 1
    var squashY: CGFloat = 1
    var tilt: Double = 0          // degrees
    var shake: CGFloat = 0        // fraction of width
    var glow: CGFloat = 0.55

    static func lerp(_ a: Pose, _ b: Pose, _ t: CGFloat) -> Pose {
        func l(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * t }
        var p = t < 0.5 ? a : b
        p.eyeW = l(a.eyeW, b.eyeW); p.eyeH = l(a.eyeH, b.eyeH); p.lid = l(a.lid, b.lid)
        p.mouthSize = l(a.mouthSize, b.mouthSize)
        p.gaze = CGPoint(x: l(a.gaze.x, b.gaze.x), y: l(a.gaze.y, b.gaze.y))
        p.hop = l(a.hop, b.hop); p.squashX = l(a.squashX, b.squashX); p.squashY = l(a.squashY, b.squashY)
        p.tilt = Double(l(CGFloat(a.tilt), CGFloat(b.tilt))); p.shake = l(a.shake, b.shake); p.glow = l(a.glow, b.glow)
        return p
    }
}

// MARK: - The mark

struct SpaceMark: View {
    var mood: SpaceMood = .idle
    var palette: [Color]? = nil
    /// Cut-out color of the eyes and mouth (the mark usually sits on black).
    var eyeColor: Color = .black
    var animated = true
    /// React to moments, the pointer and the voice level.
    var reactive = false

    @State private var previousMood: SpaceMood = .idle
    @State private var moodChangedAt: TimeInterval = 0
    @State private var anchor = ViewAnchor()

    var body: some View {
        GeometryReader { geo in
            if animated {
                TimelineView(.animation(minimumInterval: 1 / 60)) { context in
                    frame(size: geo.size, t: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                frame(size: geo.size, t: 1)
            }
        }
        .aspectRatio(1.55, contentMode: .fit)
        .background {
            // Only reactive marks follow the pointer (and ImageRenderer can't draw AppKit views).
            if reactive { AnchorView(anchor: anchor) }
        }
        .onChange(of: mood) { old, _ in
            previousMood = old
            moodChangedAt = Date.timeIntervalSinceReferenceDate
        }
    }

    // MARK: Frame

    @ViewBuilder
    private func frame(size: CGSize, t: TimeInterval) -> some View {
        let pose = currentPose(t: t, size: size)
        let w = size.width, h = size.height
        let colors = palette ?? Self.palette(for: effectiveMood(t: t), t: t)
        let bodyFill = LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)

        ZStack {
            particles(size: size, t: t)
            ZStack {
                SpaceKeyShape()
                    .fill(bodyFill)
                // Key-cap highlight along the top edge.
                SpaceKeyShape()
                    .stroke(Color.white.opacity(0.22), lineWidth: max(0.5, h * 0.035))
                    .padding(h * 0.06)
                    .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center))
                face(pose: pose, w: w, h: h)
            }
            .scaleEffect(x: pose.squashX, y: pose.squashY, anchor: .bottom)
            .rotationEffect(.degrees(pose.tilt), anchor: .bottom)
            .offset(x: pose.shake * w, y: -pose.hop * h)
            .shadow(color: (colors.dropFirst().first ?? .accentColor).opacity(Double(pose.glow)), radius: max(2, h * 0.28))
        }
        .frame(width: w, height: h)
    }

    private func face(pose: Pose, w: CGFloat, h: CGFloat) -> some View {
        let eyeW = pose.eyeW * w, eyeH = pose.eyeH * h
        let dx = pose.gaze.x * w * 0.075, dy = pose.gaze.y * h * 0.09
        let eyeY = h * 0.44 + dy
        return ZStack {
            ForEach([0.36, 0.64], id: \.self) { x in
                eye(pose: pose, width: eyeW, height: eyeH)
                    .position(x: w * x + dx, y: eyeY)
            }
            mouth(pose: pose, w: w, h: h)
                .position(x: w * 0.5 + dx * 0.6, y: h * 0.72 + dy * 0.5)
        }
    }

    @ViewBuilder
    private func eye(pose: Pose, width: CGFloat, height: CGFloat) -> some View {
        switch pose.eye {
        case .open:
            let open = max(0.08, 1 - pose.lid)
            Capsule()
                .fill(eyeColor)
                .frame(width: width, height: max(width * 0.35, height * open))
                .offset(y: height * (1 - open) * 0.35)
        case .happy:
            HappyEye()
                .stroke(eyeColor, style: StrokeStyle(lineWidth: width * 0.75, lineCap: .round))
                .frame(width: width * 1.5, height: height * 0.35)
        case .cross:
            ZStack {
                Capsule().fill(eyeColor).frame(width: width * 0.55, height: height * 0.8).rotationEffect(.degrees(45))
                Capsule().fill(eyeColor).frame(width: width * 0.55, height: height * 0.8).rotationEffect(.degrees(-45))
            }
        }
    }

    @ViewBuilder
    private func mouth(pose: Pose, w: CGFloat, h: CGFloat) -> some View {
        let s = pose.mouthSize
        switch pose.mouth {
        case .none:
            EmptyView()
        case .smile:
            MouthArc(curve: 0.9)
                .stroke(eyeColor, style: StrokeStyle(lineWidth: h * 0.07, lineCap: .round))
                .frame(width: w * 0.16 * s, height: h * 0.14)
        case .frown:
            MouthArc(curve: -0.7)
                .stroke(eyeColor, style: StrokeStyle(lineWidth: h * 0.07, lineCap: .round))
                .frame(width: w * 0.13 * s, height: h * 0.12)
        case .o:
            Ellipse().fill(eyeColor).frame(width: w * 0.07 * s, height: h * 0.13 * s)
        case .flat:
            Capsule().fill(eyeColor).frame(width: w * 0.1 * s, height: h * 0.055)
        }
    }

    // MARK: Particles

    @ViewBuilder
    private func particles(size: CGSize, t: TimeInterval) -> some View {
        let w = size.width, h = size.height
        let mood = effectiveMood(t: t)
        ZStack {
            if mood == .offline {
                // z's drifting up and away.
                ForEach(0..<3, id: \.self) { i in
                    let phase = (t * 0.35 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    Text("z")
                        .font(.system(size: h * (0.22 + 0.16 * phase), weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.gray.opacity(0.9 * (1 - phase)))
                        .position(x: w * (0.82 + 0.18 * phase), y: h * (0.2 - 0.55 * phase))
                }
            }
            if mood == .attention {
                let bob = abs(sin(t * 5)) * h * 0.12
                Text("!")
                    .font(.system(size: h * 0.5, weight: .black, design: .rounded))
                    .foregroundStyle(.yellow)
                    .position(x: w * 0.96, y: -h * 0.12 - bob)
            }
            if mood == .listening, reactive {
                // Sound rings spreading from both sides, stronger when you're louder.
                let level = CGFloat(VoiceInput.shared.level)
                ForEach(0..<2, id: \.self) { i in
                    let phase = CGFloat((t * 1.6 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1))
                    ForEach([-1.0, 1.0], id: \.self) { side in
                        Circle()
                            .trim(from: 0.38, to: 0.62)
                            .stroke(Color(red: 1.0, green: 0.55, blue: 0.55).opacity(Double((1 - phase) * (0.25 + level))),
                                    style: StrokeStyle(lineWidth: h * 0.06, lineCap: .round))
                            .frame(width: h * (0.9 + phase * 0.9), height: h * (0.9 + phase * 0.9))
                            .rotationEffect(.degrees(side < 0 ? 0 : 180))
                            .position(x: w * 0.5 + CGFloat(side) * (w * 0.42 + phase * h * 0.35), y: h * 0.5)
                    }
                }
            }
            if reactive {
                let decided = SpaceMarkEvents.age(.decided, now: t)
                if decided < 0.7 {
                    let p = CGFloat(decided / 0.7)
                    Image(systemName: "sparkle")
                        .font(.system(size: h * (0.35 + 0.25 * sin(p * .pi)), weight: .bold))
                        .foregroundStyle(Color(red: 0.75, green: 0.6, blue: 1.0).opacity(Double(1 - p)))
                        .rotationEffect(.degrees(Double(p) * 120))
                        .position(x: w * (0.92 + 0.1 * p), y: -h * (0.05 + 0.35 * p))
                }
                let success = SpaceMarkEvents.age(.success, now: t)
                if success < 0.9 {
                    let p = CGFloat(success / 0.9)
                    ForEach(0..<5, id: \.self) { i in
                        let angle = Double(i) / 5 * 2 * .pi - .pi / 2
                        Circle()
                            .fill([Color.mint, .yellow, .cyan, .pink, .green][i].opacity(Double(1 - p)))
                            .frame(width: h * 0.12, height: h * 0.12)
                            .position(x: w * 0.5 + CGFloat(cos(angle)) * w * 0.45 * (0.6 + p),
                                      y: h * 0.4 + CGFloat(sin(angle)) * h * 0.8 * (0.6 + p))
                    }
                }
            }
        }
        .frame(width: w, height: h)
        .allowsHitTesting(false)
    }

    // MARK: Behaviour

    /// Moments can override the mood for a little while (a success is happy for a beat).
    private func effectiveMood(t: TimeInterval) -> SpaceMood {
        guard reactive else { return mood }
        if SpaceMarkEvents.age(.success, now: t) < 1.4, mood != .attention, mood != .listening { return .happy }
        return mood
    }

    private func currentPose(t: TimeInterval, size: CGSize) -> Pose {
        let mood = effectiveMood(t: t)
        var pose = Self.pose(for: mood, t: t)
        // Blend from the previous mood over a quarter second.
        let since = t - moodChangedAt
        if since < 0.28, previousMood != mood, moodChangedAt > 0 {
            let k = CGFloat(Self.ease(since / 0.28))
            pose = Pose.lerp(Self.pose(for: previousMood, t: t), pose, k)
        }
        guard animated else { return pose }
        applyBlink(&pose, mood: mood, t: t)
        if reactive { react(&pose, mood: mood, t: t, size: size) } else if mood == .idle { pose.gaze = Self.idleGlance(t) }
        return pose
    }

    private static func pose(for mood: SpaceMood, t: TimeInterval) -> Pose {
        var p = Pose()
        let breath = CGFloat(sin(t * 2.1)) * 0.018
        p.squashY = 1 + breath
        p.squashX = 1 - breath * 0.5
        switch mood {
        case .idle:
            break
        case .thinking:
            p.eyeW = 0.1; p.eyeH = 0.3
            p.gaze = CGPoint(x: cos(t * 2.6) * 0.85, y: -0.45 + sin(t * 2.6) * 0.35)
            p.tilt = sin(t * 1.3) * 3
            p.mouth = .flat; p.mouthSize = 0.6
        case .working:
            p.eyeH = 0.3; p.lid = 0.45
            p.gaze = CGPoint(x: sin(t * 7) > 0 ? 0.35 : -0.15, y: 0.55)   // reading lines of work
            p.hop = CGFloat(abs(sin(t * 6))) * 0.035
            p.mouth = .flat; p.mouthSize = 0.8
        case .attention:
            p.eyeW = 0.14; p.eyeH = 0.42
            p.hop = CGFloat(abs(sin(t * 5))) * 0.12
            let landing = CGFloat(max(0, cos(t * 10))) * 0.06
            p.squashY = 1 - landing; p.squashX = 1 + landing
            p.mouth = .o; p.mouthSize = 1
            p.glow = 0.8
        case .listening:
            p.eyeW = 0.15; p.eyeH = 0.3
            p.mouth = .o; p.mouthSize = 0.7
            p.glow = 0.7
        case .happy:
            p.eye = .happy
            p.mouth = .smile
            p.hop = CGFloat(abs(sin(t * 7))) * 0.07
            p.glow = 0.75
        case .offline:
            p.lid = 0.92
            p.gaze = CGPoint(x: 0, y: 0.35)
            p.squashY = 1 + CGFloat(sin(t * 1.2)) * 0.04   // slow, deep breathing
            p.tilt = 4
            p.glow = 0
        }
        return p
    }

    private func applyBlink(_ pose: inout Pose, mood: SpaceMood, t: TimeInterval) {
        guard pose.eye == .open, mood != .offline else { return }
        // Every 3–5 s (varies), sometimes a double blink.
        let slot = floor(t / 4)
        let jitter = Self.noise(slot) * 1.6
        let phase = t - slot * 4 - jitter
        let double = Self.noise(slot + 91) > 0.7
        if (0..<0.13).contains(phase) || (double && (0.22..<0.33).contains(phase)) {
            pose.lid = max(pose.lid, 0.92)
        }
    }

    private func react(_ pose: inout Pose, mood: SpaceMood, t: TimeInterval, size: CGSize) {
        let events = SpaceMarkEvents.self

        // Where to look: the text being typed > the work > the pointer > glancing around.
        let typing = events.age(.keystroke, now: t)
        let (pointer, pointerIdle) = events.pointerSample(now: t)
        if typing < 1.4, mood == .idle || mood == .thinking {
            let along = min(1, 0.25 + CGFloat(events.typedLength) / 28)
            pose.gaze = CGPoint(x: along, y: 0.2)
        } else if pointerIdle < 3, mood == .idle || mood == .listening, let center = anchor.screenCenter {
            let dx = pointer.x - center.x, dy = center.y - pointer.y
            let distance = max(1, hypot(dx, dy))
            let reach = min(1, distance / 220)
            pose.gaze = CGPoint(x: dx / distance * reach, y: dy / distance * reach * 0.8)
        } else if mood == .idle {
            pose.gaze = Self.idleGlance(t)
        }

        // Keystroke: a small hop with a squash on landing.
        if typing < 0.32 {
            let p = typing / 0.32
            pose.hop += CGFloat(sin(p * .pi)) * 0.07
            pose.squashY *= 1 + CGFloat(sin(p * .pi)) * 0.05
        }

        // Snap 1 decided: eyes pop.
        let decided = events.age(.decided, now: t)
        if decided < 0.45 {
            let pop = CGFloat(sin(decided / 0.45 * .pi)) * 0.35
            pose.eyeW *= 1 + pop; pose.eyeH *= 1 + pop
            pose.lid = 0
        }

        // Send: wind up (squash), then launch (stretch and leap), eyes squeezed happy.
        let send = events.age(.send, now: t)
        if send < 0.6 {
            if send < 0.1 {
                let k = CGFloat(send / 0.1)
                pose.squashY *= 1 - 0.2 * k; pose.squashX *= 1 + 0.15 * k
            } else {
                let p = (send - 0.1) / 0.5
                let arc = CGFloat(sin(p * .pi))
                pose.hop += arc * 0.32
                pose.squashY *= 1 + arc * 0.16; pose.squashX *= 1 - arc * 0.1
                pose.tilt += Double(arc) * -8
            }
            pose.eye = .happy
        }

        // Error: shake, X eyes, frown.
        let error = events.age(.error, now: t)
        if error < 1.1 {
            let decay = CGFloat(max(0, 1 - error / 0.6))
            pose.shake = CGFloat(sin(error * 45)) * 0.05 * decay
            pose.eye = .cross
            pose.mouth = .frown
        }

        // Approval asked: one big startled jump on top of the attention bounce.
        let attention = events.age(.attention, now: t)
        if attention < 0.5 {
            pose.hop += CGFloat(sin(attention / 0.5 * .pi)) * 0.25
            pose.eyeW *= 1.2; pose.eyeH *= 1.2
        }

        // Listening: the whole body swells with your voice.
        if mood == .listening {
            let level = CGFloat(VoiceInput.shared.level)
            pose.squashY *= 1 + level * 0.16
            pose.squashX *= 1 + level * 0.06
            pose.eyeW *= 1 + level * 0.35; pose.eyeH *= 1 + level * 0.25
            pose.mouthSize = 0.5 + level * 1.4
            pose.glow = 0.5 + level * 0.5
        }
    }

    /// Looks somewhere new every couple of seconds, with a quick saccade between spots.
    private static func idleGlance(_ t: TimeInterval) -> CGPoint {
        let slot = floor(t / 2.4)
        let target = CGPoint(x: noise(slot) * 1.6 - 0.8, y: noise(slot + 17) * 0.9 - 0.45)
        let prior = CGPoint(x: noise(slot - 1) * 1.6 - 0.8, y: noise(slot + 16) * 0.9 - 0.45)
        let k = CGFloat(ease(min(1, (t - slot * 2.4) / 0.12)))
        // Half the time it just looks straight ahead.
        let look = noise(slot + 5) > 0.5 ? target : .zero
        let from = noise(slot + 4) > 0.5 ? prior : .zero
        return CGPoint(x: from.x + (look.x - from.x) * k, y: from.y + (look.y - from.y) * k)
    }

    /// Deterministic 0…1 noise for a slot number.
    private static func noise(_ x: Double) -> CGFloat {
        let v = sin(x * 12.9898 + 78.233) * 43758.5453
        return CGFloat(v - floor(v))
    }

    private static func ease(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return c * c * (3 - 2 * c)
    }

    static func palette(for mood: SpaceMood, t: TimeInterval) -> [Color] {
        switch mood {
        case .attention: return [.yellow, .orange, Color(red: 1, green: 0.5, blue: 0.2)]
        case .listening: return [Color(red: 1.0, green: 0.45, blue: 0.55), Color(red: 1.0, green: 0.55, blue: 0.45), Color(red: 1.0, green: 0.68, blue: 0.3)]
        case .offline: return [Color(white: 0.55), Color(white: 0.4), Color(white: 0.3)]
        case .happy: return [Color(red: 0.45, green: 0.95, blue: 0.75), Color(red: 0.4, green: 0.8, blue: 1.0), Color(red: 0.6, green: 0.55, blue: 1.0)]
        default: return [Color(red: 0.55, green: 0.85, blue: 1.0), Color(red: 0.36, green: 0.56, blue: 1.0), Color(red: 0.72, green: 0.45, blue: 1.0)]
        }
    }
}

/// The mark with a soft glow, for headers, the bar and the pill.
struct SpaceMarkBadge: View {
    var mood: SpaceMood
    var reactive = false

    var body: some View {
        SpaceMark(mood: mood, reactive: reactive)
    }
}

// MARK: - Screen position (for following the pointer)

private final class ViewAnchor {
    weak var view: NSView?

    var screenCenter: CGPoint? {
        guard let view, let window = view.window else { return nil }
        let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
        return CGPoint(x: rect.midX, y: rect.midY)
    }
}

private struct AnchorView: NSViewRepresentable {
    let anchor: ViewAnchor
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { anchor.view = nsView }
}

// MARK: - Menu bar

extension SpaceMark {
    /// A template image of the mark for the menu bar (eyes cut out).
    @MainActor
    static func menuBarImage() -> NSImage {
        let size = NSSize(width: 22, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            let body = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1.5), xRadius: 4.6, yRadius: 4.6)
            NSColor.black.setFill()
            body.fill()
            NSGraphicsContext.current?.compositingOperation = .clear
            for x in [7.0, 13.0] {
                NSBezierPath(roundedRect: NSRect(x: x, y: 5.3, width: 2.2, height: 4.4), xRadius: 1.1, yRadius: 1.1).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

// MARK: - Voice

/// Live microphone bars driven by the input level.
struct VoiceWaveform: View {
    var level: Float
    var bars = 5
    var color: Color = Color(red: 1.0, green: 0.5, blue: 0.5)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<bars, id: \.self) { i in
                    let wobble = 0.55 + 0.45 * sin(t * 9 + Double(i) * 1.3)
                    let height = 0.18 + 0.82 * CGFloat(level) * CGFloat(wobble)
                    Capsule()
                        .fill(color)
                        .frame(width: 2.5)
                        .frame(maxHeight: .infinity)
                        .scaleEffect(y: max(0.18, height), anchor: .center)
                }
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }
}
