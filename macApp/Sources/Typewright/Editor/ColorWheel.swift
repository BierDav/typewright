import AppKit
import SwiftUI

/// Hue and saturation wheel with brightness and opacity sliders, shown in a popover on a color swatch.
struct ColorWheel: View {
    let onChange: (NSColor) -> Void
    let onShowPanel: () -> Void
    @State private var hue: Double
    @State private var saturation: Double
    @State private var brightness: Double
    @State private var alpha: Double

    private static let size: CGFloat = 180

    init(color: NSColor, onChange: @escaping (NSColor) -> Void, onShowPanel: @escaping () -> Void) {
        let c = color.usingColorSpace(.sRGB) ?? color
        _hue = State(initialValue: c.hueComponent)
        _saturation = State(initialValue: c.saturationComponent)
        _brightness = State(initialValue: c.brightnessComponent)
        _alpha = State(initialValue: c.alphaComponent)
        self.onChange = onChange
        self.onShowPanel = onShowPanel
    }

    private var color: NSColor {
        NSColor(colorSpace: .sRGB, hue: hue, saturation: saturation, brightness: brightness, alpha: alpha)
    }

    var body: some View {
        VStack(spacing: 12) {
            wheel
            Grid(alignment: .leading, verticalSpacing: 8) {
                GridRow {
                    Text("Brightness")
                    Slider(value: $brightness, in: 0...1)
                }
                GridRow {
                    Text("Opacity")
                    Slider(value: $alpha, in: 0...1)
                }
            }
            HStack {
                Text(hex)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                Button("Colors…", action: onShowPanel)
                    .controlSize(.small)
                    .help("Open the system color panel, with its eyedropper and palettes")
            }
        }
        .font(.callout)
        .padding(14)
        .frame(width: Self.size + 60)
        .onChange(of: [hue, saturation, brightness, alpha]) { onChange(color) }
    }

    private var wheel: some View {
        let radius = Self.size / 2
        // SwiftUI angles run clockwise from the right, matching the hue gradient.
        let angle = hue * 2 * .pi
        let knob = CGPoint(x: radius + cos(angle) * saturation * radius, y: radius + sin(angle) * saturation * radius)
        return ZStack {
            Circle().fill(AngularGradient(colors: (0...12).map { Color(hue: Double($0) / 12, saturation: 1, brightness: 1) },
                                          center: .center))
            Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center, startRadius: 0, endRadius: radius))
            Circle().fill(Color.black.opacity(1 - brightness))
            Circle()
                .fill(Color(nsColor: color.withAlphaComponent(1)))
                .frame(width: 18, height: 18)
                .overlay(Circle().stroke(.white, lineWidth: 2.5))
                .shadow(color: .black.opacity(0.35), radius: 2)
                .position(knob)
        }
        .frame(width: Self.size, height: Self.size)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            let dx = value.location.x - radius, dy = value.location.y - radius
            let a = atan2(dy, dx)
            hue = (a < 0 ? a + 2 * .pi : a) / (2 * .pi)
            saturation = min(hypot(dx, dy) / radius, 1)
        })
    }

    private var hex: String {
        let c = color
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        let rgb = String(format: "#%02x%02x%02x", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
        return byte(alpha) == 255 ? rgb : rgb + String(format: "%02x", byte(alpha))
    }
}
