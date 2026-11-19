import SwiftUI

struct JoystickPad: View {
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.scenePhase) private var scenePhase
    @State private var voiceOverVector = CGVector.zero
    @State private var lastVector = CGVector.zero
    @GestureState private var isTouching = false
    let onDirection: (Double, Double) -> Void

    private let radius = 48.0
    private let size = 144.0

    var body: some View {
        Group {
            if voiceOver {
                accessibleDirections
            } else {
                pad
            }
        }
        .frame(maxWidth: .infinity)
        .onChange(of: isTouching) { _, touching in
            if !touching && !voiceOver { release() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { release() }
        }
        .onChange(of: voiceOver) { _, _ in release() }
        .onDisappear(perform: release)
    }

    private var pad: some View {
        ZStack {
            Circle().fill(.primary.opacity(0.07))
            Circle().strokeBorder(.primary.opacity(0.18))
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.title2)
                .foregroundStyle(.secondary)
            Circle()
                .fill(Color.accentColor)
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 2))
                .frame(width: 44, height: 44)
                .offset(x: lastVector.dx * radius, y: -lastVector.dy * radius)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .updating($isTouching) { _, state, _ in state = true }
            .onChanged { value in
                let dx = value.location.x - size / 2
                let dy = size / 2 - value.location.y
                let distance = hypot(dx, dy)
                guard distance > 6 else {
                    setVector(.zero)
                    return
                }
                let fraction = min((distance - 6) / (radius - 6), 1)
                setVector(CGVector(dx: dx / distance * fraction, dy: dy / distance * fraction))
            }
            .onEnded { _ in release() })
        .accessibilityHidden(true)
    }

    private var accessibleDirections: some View {
        VStack(spacing: 4) {
            direction(.init(dx: 0, dy: 1), "Move north", "arrow.up")
            HStack(spacing: 8) {
                direction(.init(dx: -1, dy: 0), "Move west", "arrow.left")
                Button(action: release) {
                    Image(systemName: "stop.fill").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Stop moving")
                direction(.init(dx: 1, dy: 0), "Move east", "arrow.right")
            }
            direction(.init(dx: 0, dy: -1), "Move south", "arrow.down")
        }
        .environment(\.layoutDirection, .leftToRight)
        .buttonStyle(.bordered)
    }

    private func direction(_ vector: CGVector, _ title: LocalizedStringKey, _ symbol: String) -> some View {
        Button {
            let next = voiceOverVector == vector ? .zero : vector
            voiceOverVector = next
            setVector(next)
        } label: {
            Image(systemName: symbol).frame(width: 44, height: 44)
        }
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(voiceOverVector == vector ? .isSelected : [])
    }

    private func release() {
        voiceOverVector = .zero
        setVector(.zero)
    }

    private func setVector(_ vector: CGVector) {
        guard lastVector != vector else { return }
        lastVector = vector
        onDirection(vector.dx, vector.dy)
    }
}
