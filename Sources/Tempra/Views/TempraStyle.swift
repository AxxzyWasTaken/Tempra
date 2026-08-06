import AppKit
import SwiftUI

enum TempraLayout {
    static let mainPanelSize = CGSize(width: 360, height: 760)
    static let mainNotchHeight: CGFloat = 10
    static let inspectorBodyWidth: CGFloat = 300
    static let inspectorNotchWidth: CGFloat = 10
    static let inspectorSize = CGSize(
        width: inspectorBodyWidth + inspectorNotchWidth,
        height: 420
    )
    static let settingsPanelSize = CGSize(width: 420, height: 400)
    static let highCPUAlertPanelSize = CGSize(width: 344, height: 252)
    static let panelCornerRadius: CGFloat = 16
    static let processRowHeight: CGFloat = 28
    static let processRowHorizontalInset: CGFloat = 8
    static let processColumnSpacing: CGFloat = 8
    static let currentCPUColumnWidth: CGFloat = 46
    static let averageCPUColumnWidth: CGFloat = 50
}

enum TempraPalette {
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? dark
                : light
        })
    }

    private static func color(
        _ red: CGFloat,
        _ green: CGFloat,
        _ blue: CGFloat,
        alpha: CGFloat = 1
    ) -> NSColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
    }

    private static let panelTop = adaptive(
        light: color(0.97, 0.98, 0.99, alpha: 0.72),
        dark: color(0.12, 0.13, 0.15, alpha: 0.58)
    )
    private static let panelMiddle = adaptive(
        light: color(0.96, 0.97, 0.98, alpha: 0.58),
        dark: color(0.10, 0.11, 0.13, alpha: 0.48)
    )
    private static let panelBottom = adaptive(
        light: color(0.95, 0.96, 0.98, alpha: 0.48),
        dark: color(0.08, 0.09, 0.11, alpha: 0.40)
    )

    static let panelTint = LinearGradient(
        colors: [panelTop, panelMiddle, panelBottom],
        startPoint: .top,
        endPoint: .bottom
    )
    static let primaryText = Color(nsColor: .labelColor)
    static let secondaryText = Color(nsColor: .secondaryLabelColor)
    static let tertiaryText = Color(nsColor: .tertiaryLabelColor)
    static let accent = adaptive(
        light: color(0.00, 0.45, 0.92),
        dark: color(0.24, 0.62, 1.00)
    )
    static let chartFill = adaptive(
        light: color(1.00, 1.00, 1.00, alpha: 0.48),
        dark: color(1.00, 1.00, 1.00, alpha: 0.04)
    )
    static let chartPlotFill = adaptive(
        light: color(1.00, 1.00, 1.00, alpha: 0.18),
        dark: color(0.00, 0.00, 0.00, alpha: 0.08)
    )
    static let selectedRow = adaptive(
        light: color(0.00, 0.45, 0.92, alpha: 0.12),
        dark: color(1.00, 1.00, 1.00, alpha: 0.10)
    )
    static let border = adaptive(
        light: color(0.10, 0.12, 0.16, alpha: 0.10),
        dark: color(1.00, 1.00, 1.00, alpha: 0.10)
    )
    static let separator = adaptive(
        light: color(0.12, 0.14, 0.18, alpha: 0.10),
        dark: color(1.00, 1.00, 1.00, alpha: 0.08)
    )
    static let controlFill = adaptive(
        light: color(1.00, 1.00, 1.00, alpha: 0.78),
        dark: color(1.00, 1.00, 1.00, alpha: 0.10)
    )
    static let secondaryControlFill = adaptive(
        light: color(0.10, 0.12, 0.16, alpha: 0.05),
        dark: color(1.00, 1.00, 1.00, alpha: 0.06)
    )
    static let searchFill = adaptive(
        light: color(0.10, 0.12, 0.16, alpha: 0.06),
        dark: color(1.00, 1.00, 1.00, alpha: 0.08)
    )
    static let fieldFill = adaptive(
        light: color(1.00, 1.00, 1.00, alpha: 0.84),
        dark: color(0.00, 0.00, 0.00, alpha: 0.28)
    )
    static let subtleFill = adaptive(
        light: color(0.10, 0.12, 0.16, alpha: 0.03),
        dark: color(1.00, 1.00, 1.00, alpha: 0.03)
    )
    static let chartBorder = adaptive(
        light: color(0.12, 0.14, 0.18, alpha: 0.12),
        dark: color(1.00, 1.00, 1.00, alpha: 0.10)
    )
    static let chartGrid = adaptive(
        light: color(0.12, 0.14, 0.18, alpha: 0.08),
        dark: color(1.00, 1.00, 1.00, alpha: 0.08)
    )
    static let sliderTrack = adaptive(
        light: color(0.10, 0.14, 0.22, alpha: 0.28),
        dark: color(1.00, 1.00, 1.00, alpha: 0.28)
    )
    static let sliderThumb = adaptive(
        light: color(1.00, 1.00, 1.00, alpha: 0.98),
        dark: color(1.00, 1.00, 1.00, alpha: 0.96)
    )
    static let switchTrackOff = adaptive(
        light: color(0.12, 0.16, 0.24, alpha: 0.18),
        dark: color(1.00, 1.00, 1.00, alpha: 0.20)
    )
    static let prominentButtonFill = adaptive(
        light: color(1.00, 1.00, 1.00, alpha: 0.82),
        dark: color(1.00, 1.00, 1.00, alpha: 0.92)
    )
    static let prominentButtonText = adaptive(
        light: color(0.08, 0.10, 0.14, alpha: 0.92),
        dark: color(0.04, 0.05, 0.08, alpha: 0.88)
    )
    static let performance = adaptive(
        light: color(0.76, 0.25, 0.03),
        dark: color(1.00, 0.51, 0.28)
    )
    static let efficiency = adaptive(
        light: color(0.00, 0.43, 0.67),
        dark: color(0.25, 0.82, 0.96)
    )
    static let saved = adaptive(
        light: color(0.08, 0.49, 0.12),
        dark: color(0.36, 0.83, 0.34)
    )
    static let thermal = adaptive(
        light: color(0.64, 0.16, 0.60),
        dark: color(0.91, 0.39, 0.88)
    )
    static let slowed = adaptive(
        light: color(0.00, 0.45, 0.67),
        dark: color(0.20, 0.72, 0.90)
    )
    static let waiting = adaptive(
        light: color(0.70, 0.39, 0.00),
        dark: color(0.98, 0.68, 0.19)
    )
    static let stopped = adaptive(
        light: color(0.78, 0.08, 0.07),
        dark: color(0.96, 0.20, 0.18)
    )
    static let running = adaptive(
        light: color(0.38, 0.40, 0.38),
        dark: color(0.47, 0.48, 0.43)
    )
    static let efficiencyArea = LinearGradient(
        colors: [efficiency.opacity(0.62), efficiency.opacity(0.34)],
        startPoint: .top,
        endPoint: .bottom
    )
    static let performanceArea = LinearGradient(
        colors: [performance.opacity(0.82), performance.opacity(0.48)],
        startPoint: .top,
        endPoint: .bottom
    )
}

enum TempraTypography {
    static let title = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 12, weight: .regular)
    static let bodyEmphasized = Font.system(size: 12, weight: .semibold)
    static let metric = Font.system(size: 11, weight: .regular)
    static let metricValue = Font.system(size: 12, weight: .medium).monospacedDigit()
    static let process = Font.system(size: 12.5, weight: .regular)
    static let processValue = Font.system(size: 12, weight: .medium).monospacedDigit()
    static let ruleTag = Font.system(size: 10.5, weight: .medium)
    static let sectionHeading = Font.system(size: 11, weight: .semibold)
    static let tableHeader = Font.system(size: 11, weight: .medium)
    static let footer = Font.system(size: 11, weight: .regular)
    static let heroValue = Font.system(size: 28, weight: .semibold).monospacedDigit()
    static let heroLabel = Font.system(size: 11, weight: .medium)
}

struct MainPanelShape: Shape {
    var arrowX: CGFloat? = nil

    func path(in rect: CGRect) -> Path {
        let radius = min(TempraLayout.panelCornerRadius, rect.width / 2)
        let notchHeight = TempraLayout.mainNotchHeight
        let notchHalfWidth: CGFloat = 11
        let bodyTop = rect.minY + notchHeight
        let midpoint = min(
            max(arrowX ?? rect.midX, rect.minX + radius + notchHalfWidth),
            rect.maxX - radius - notchHalfWidth
        )

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: bodyTop))
        path.addLine(to: CGPoint(x: midpoint - notchHalfWidth, y: bodyTop))
        path.addLine(to: CGPoint(x: midpoint, y: rect.minY))
        path.addLine(to: CGPoint(x: midpoint + notchHalfWidth, y: bodyTop))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: bodyTop))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: bodyTop + radius),
            control: CGPoint(x: rect.maxX, y: bodyTop)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: bodyTop + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: bodyTop),
            control: CGPoint(x: rect.minX, y: bodyTop)
        )
        path.closeSubpath()
        return path
    }
}

struct MonitorPanelShape: Shape {
    let isDetached: Bool

    func path(in rect: CGRect) -> Path {
        if isDetached {
            return RoundedRectangle(
                cornerRadius: TempraLayout.panelCornerRadius,
                style: .continuous
            ).path(in: rect)
        }
        return MainPanelShape().path(in: rect)
    }
}

struct InspectorPanelShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(TempraLayout.panelCornerRadius, rect.height / 2)
        let bodyRight = rect.maxX - TempraLayout.inspectorNotchWidth
        let pointerHalfHeight: CGFloat = 10

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: bodyRight - radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: bodyRight, y: rect.minY + radius),
            control: CGPoint(x: bodyRight, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: bodyRight, y: rect.midY - pointerHalfHeight))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: bodyRight, y: rect.midY + pointerHalfHeight))
        path.addLine(to: CGPoint(x: bodyRight, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: bodyRight - radius, y: rect.maxY),
            control: CGPoint(x: bodyRight, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

private struct TempraVisualEffectView: NSViewRepresentable {
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.material = .popover
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = false
    }
}

private struct TempraPanelSurface<PanelShape: Shape>: ViewModifier {
    let shape: PanelShape
    let blendingMode: NSVisualEffectView.BlendingMode

    func body(content: Content) -> some View {
        content
            .tint(TempraPalette.accent)
            .background {
                ZStack {
                    TempraVisualEffectView(blendingMode: blendingMode)
                    shape.fill(TempraPalette.panelTint)
                }
                .clipShape(shape)
            }
            .clipShape(shape)
            .overlay {
                shape.stroke(TempraPalette.border, lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            .foregroundStyle(TempraPalette.primaryText)
    }
}

enum TempraDotFill {
    case none
    case half
    case full
}

private struct TempraDiagonalHalf: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct TempraStatusDot: View {
    let color: Color
    let fill: TempraDotFill
    var size: CGFloat = 9

    var body: some View {
        ZStack {
            Circle()
                .fill(TempraPalette.running)

            switch fill {
            case .none:
                EmptyView()
            case .half:
                TempraDiagonalHalf()
                    .fill(color)
                    .clipShape(Circle())
            case .full:
                Circle()
                    .fill(color)
            }
        }
        .frame(width: size, height: size)
        .overlay {
            Circle()
                .stroke(TempraPalette.border.opacity(0.35), lineWidth: 0.5)
        }
    }
}

extension View {
    func tempraPanelSurface<PanelShape: Shape>(
        _ shape: PanelShape,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) -> some View {
        modifier(TempraPanelSurface(shape: shape, blendingMode: blendingMode))
    }

    func tempraAppearance(_ appearance: AppAppearance) -> some View {
        preferredColorScheme(appearance.colorScheme)
    }
}

extension AppAppearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

struct TempraSwitchToggleStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(
                        configuration.isOn
                            ? TempraPalette.accent
                            : TempraPalette.switchTrackOff
                    )
                    .frame(width: 40, height: 22)

                Circle()
                    .fill(TempraPalette.sliderThumb)
                    .frame(width: 18, height: 18)
                    .padding(2)
            }
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.16),
                value: configuration.isOn
            )
        }
        .buttonStyle(.plain)
    }
}

struct TempraCheckboxToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(
                            configuration.isOn
                                ? TempraPalette.accent
                                : TempraPalette.controlFill
                        )
                        .overlay {
                            if !configuration.isOn {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .stroke(TempraPalette.border.opacity(0.7), lineWidth: 0.5)
                            }
                        }

                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .black))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 13, height: 13)

                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.12),
            value: configuration.isOn
        )
    }
}

struct TempraNumberField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var width: CGFloat = 46
    var suffix = ""
    var accented = false

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 1) {
            TextField(
                "Value",
                value: $value,
                format: .number.precision(.fractionLength(0))
            )
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .focused($isFocused)

            if !suffix.isEmpty {
                Text(suffix)
                    .foregroundStyle(TempraPalette.secondaryText)
            }
        }
        .font(TempraTypography.bodyEmphasized.monospacedDigit())
        .padding(.horizontal, 6)
        .frame(width: width, height: 22)
        .background(TempraPalette.fieldFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(
                    isFocused || accented
                        ? TempraPalette.accent
                        : TempraPalette.border.opacity(0.7),
                    lineWidth: isFocused || accented ? 2 : 0.7
                )
        }
        .onChange(of: value) { _, newValue in
            value = min(max(range.lowerBound, newValue), range.upperBound)
        }
    }
}

struct TempraTickedSlider: View {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var tickCount: Int = 11

    @FocusState private var isFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - 9)
            let progress = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(TempraPalette.sliderTrack.opacity(isEnabled ? 1 : 0.46))
                    .frame(height: 1.5)
                    .offset(y: -2)

                HStack(spacing: 0) {
                    ForEach(0..<tickCount, id: \.self) { index in
                        Circle()
                            .fill(TempraPalette.sliderTrack.opacity(isEnabled ? 0.9 : 0.4))
                            .frame(width: 2, height: 2)
                        if index < tickCount - 1 {
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.top, 10)

                Capsule()
                    .fill(TempraPalette.sliderThumb.opacity(isEnabled ? 1 : 0.62))
                    .frame(width: 9, height: 17)
                    .overlay {
                        Capsule()
                            .stroke(TempraPalette.border, lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.26), radius: 1, y: 1)
                    .offset(x: min(width, max(0, progress * width)))
            }
            .contentShape(Rectangle())
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(TempraPalette.accent.opacity(0.72), lineWidth: 1)
                        .padding(.horizontal, -3)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        isFocused = true
                        setValue(for: gesture.location.x, width: geometry.size.width)
                    }
            )
        }
        .frame(height: 20)
        .focusable(isEnabled)
        .focused($isFocused)
        .onMoveCommand { direction in
            switch direction {
            case .left, .down:
                adjust(by: -step)
            case .right, .up:
                adjust(by: step)
            default:
                break
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Value")
        .accessibilityValue(String(Int(value.rounded())))
        .accessibilityAdjustableAction { direction in
            adjust(by: direction == .increment ? step : -step)
        }
    }

    private func setValue(for x: CGFloat, width: CGFloat) {
        let fraction = min(1, max(0, x / max(1, width)))
        let raw = range.lowerBound + Double(fraction) * (range.upperBound - range.lowerBound)
        value = min(range.upperBound, max(range.lowerBound, (raw / step).rounded() * step))
    }

    private func adjust(by amount: Double) {
        guard isEnabled else { return }
        value = min(range.upperBound, max(range.lowerBound, value + amount))
    }
}
