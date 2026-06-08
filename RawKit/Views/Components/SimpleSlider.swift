import SwiftUI

/// 简化的滑块控件（无刻度，无重置按钮）
struct SimpleSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let validRange: ClosedRange<Double>
    let step: Double
    let valueFormatter: (Double) -> String
    let defaultValue: Double
    @State private var displayValue: Double

    init(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double> = 0.0...1.0,
        validRange: ClosedRange<Double>? = nil,
        step: Double = 0.01,
        defaultValue: Double = 1.0,
        valueFormatter: @escaping (Double) -> String = { String(format: "%.2f", $0) }
    ) {
        self.title = title
        self._value = value
        self.range = range
        self.validRange = validRange ?? range
        self.step = step
        self.defaultValue = defaultValue
        self.valueFormatter = valueFormatter
        self._displayValue = State(initialValue: value.wrappedValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Text(valueFormatter(displayValue))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(minWidth: 35, alignment: .trailing)
                    .monospacedDigit()
            }

            ZStack {
                SliderWithDoubleTapSmall(
                    value: Binding(
                        get: { displayValue },
                        set: handleDisplayValueChange
                    ),
                    range: range,
                    validRange: validRange,
                    onDoubleTap: resetToDefault
                )

                SliderInvalidRangeOverlay(range: range, validRange: validRange)
                    .allowsHitTesting(false)
            }
            .frame(height: 16)
        }
        .onChange(of: value) { _, newValue in
            if abs(displayValue - newValue) > 0.0001 {
                displayValue = newValue
            }
        }
        .onChange(of: range) { _, newRange in
            let clampedValue = clamp(displayValue, to: newRange)
            guard abs(clampedValue - displayValue) > 0.0001 else { return }

            displayValue = clampedValue
            let binding = _value
            DispatchQueue.main.async {
                if abs(binding.wrappedValue - clampedValue) > 0.0001 {
                    binding.wrappedValue = clampedValue
                }
            }
        }
        .onChange(of: validRange) { _, newRange in
            clampDisplayValue(to: newRange)
        }
    }

    private func handleDisplayValueChange(_ newValue: Double) {
        let steppedValue = clamp(round(newValue / step) * step, to: validRange)
        if abs(displayValue - steppedValue) > 0.0001 {
            displayValue = steppedValue
        }

        let binding = _value
        DispatchQueue.main.async {
            if abs(binding.wrappedValue - steppedValue) > 0.0001 {
                binding.wrappedValue = steppedValue
            }
        }
    }

    private func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private func clampDisplayValue(to range: ClosedRange<Double>) {
        let clampedValue = clamp(displayValue, to: range)
        guard abs(clampedValue - displayValue) > 0.0001 else { return }

        displayValue = clampedValue
        let binding = _value
        DispatchQueue.main.async {
            if abs(binding.wrappedValue - clampedValue) > 0.0001 {
                binding.wrappedValue = clampedValue
            }
        }
    }

    private func resetToDefault() {
        let clampedDefaultValue = clamp(defaultValue, to: validRange)
        displayValue = clampedDefaultValue
        let binding = _value
        DispatchQueue.main.async {
            binding.wrappedValue = clampedDefaultValue
        }
    }
}

private struct SliderInvalidRangeOverlay: View {
    let range: ClosedRange<Double>
    let validRange: ClosedRange<Double>

    var body: some View {
        GeometryReader { geometry in
            let leftWidth = trackPosition(for: validRange.lowerBound, width: geometry.size.width)
            let rightX = trackPosition(for: validRange.upperBound, width: geometry.size.width)
            let rightWidth = max(0.0, geometry.size.width - rightX)

            ZStack(alignment: .leading) {
                invalidSegment(width: leftWidth)
                    .frame(width: leftWidth)

                invalidSegment(width: rightWidth)
                    .frame(width: rightWidth)
                    .offset(x: rightX)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func invalidSegment(width: CGFloat) -> some View {
        Capsule()
            .fill(Color.secondary.opacity(width > 0.5 ? 0.28 : 0.0))
            .frame(height: 4)
            .frame(maxHeight: .infinity, alignment: .center)
    }

    private func trackPosition(for value: Double, width: CGFloat) -> CGFloat {
        let length = max(range.upperBound - range.lowerBound, 0.0001)
        let ratio = (value - range.lowerBound) / length
        return min(max(CGFloat(ratio) * width, 0.0), width)
    }
}

// 自定义 NSSlider：点击轨道时立即跳到目标值，并保留原生拖动行为
public final class TrackClickableSlider: NSSlider {
    public var onDoubleClick: (() -> Void)?
    public var validRange: ClosedRange<Double>?

    private var pendingActionSelector: Selector?
    private weak var pendingActionTarget: AnyObject?
    private var isActionDispatchQueued = false

    public override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }

        guard let sliderCell = cell as? NSSliderCell else {
            super.mouseDown(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        let knobRect = sliderCell.knobRect(flipped: isFlipped)

        if knobRect.contains(point) {
            super.mouseDown(with: event)
            return
        }

        updateValueAndSend(for: point, knobRect: knobRect)
    }

    private func updateValueAndSend(for point: NSPoint, knobRect: NSRect) {
        doubleValue = clampedToValidRange(value(at: point, knobRect: knobRect))
        needsDisplay = true
        displayIfNeeded()
        sendAction(action, to: target)
    }

    @discardableResult
    public override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        guard let action else { return false }

        pendingActionSelector = action
        pendingActionTarget = target as AnyObject?

        if isActionDispatchQueued {
            return true
        }

        isActionDispatchQueued = true
        needsDisplay = true
        displayIfNeeded()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isActionDispatchQueued = false

            guard let pendingActionSelector = self.pendingActionSelector else { return }
            let pendingActionTarget = self.pendingActionTarget
            self.pendingActionSelector = nil
            self.pendingActionTarget = nil

            NSApp.sendAction(
                pendingActionSelector,
                to: pendingActionTarget,
                from: self
            )
        }

        return true
    }

    private func value(at point: NSPoint, knobRect: NSRect) -> Double {
        if isVertical {
            let knobHeight = knobRect.height
            let usableHeight = max(bounds.height - knobHeight, 1)
            let minY = knobHeight / 2
            let maxY = bounds.height - knobHeight / 2
            let clampedY = min(max(point.y, minY), maxY)
            let ratio = Double((clampedY - minY) / usableHeight)
            return minValue + ratio * (maxValue - minValue)
        }

        let knobWidth = knobRect.width
        let usableWidth = max(bounds.width - knobWidth, 1)
        let minX = knobWidth / 2
        let maxX = bounds.width - knobWidth / 2
        let clampedX = min(max(point.x, minX), maxX)
        let ratio = Double((clampedX - minX) / usableWidth)
        return minValue + ratio * (maxValue - minValue)
    }

    private func clampedToValidRange(_ value: Double) -> Double {
        guard let validRange else { return value }
        return min(max(value, validRange.lowerBound), validRange.upperBound)
    }
}

// 小尺寸的支持双击重置的滑块
struct SliderWithDoubleTapSmall: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let validRange: ClosedRange<Double>
    let onDoubleTap: () -> Void

    init(
        value: Binding<Double>,
        range: ClosedRange<Double>,
        validRange: ClosedRange<Double>,
        onDoubleTap: @escaping () -> Void
    ) {
        self._value = value
        self.range = range
        self.validRange = validRange
        self.onDoubleTap = onDoubleTap
    }

    func makeNSView(context: Context) -> TrackClickableSlider {
        let slider = TrackClickableSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: context.coordinator, action: #selector(Coordinator.valueChanged(_:)))
        slider.isContinuous = true
        slider.controlSize = .small
        slider.validRange = validRange
        slider.onDoubleClick = onDoubleTap

        return slider
    }

    func updateNSView(_ nsView: TrackClickableSlider, context: Context) {
        nsView.minValue = range.lowerBound
        nsView.maxValue = range.upperBound
        nsView.validRange = validRange
        nsView.onDoubleClick = onDoubleTap

        // 只在值真正不同时才更新，避免干扰用户交互
        // 允许小的浮点误差（0.0001）
        let clampedValue = min(max(value, validRange.lowerBound), validRange.upperBound)
        if abs(nsView.doubleValue - clampedValue) > 0.0001 {
            nsView.doubleValue = clampedValue
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value, onDoubleTap: onDoubleTap)
    }

    class Coordinator: NSObject {
        @Binding var value: Double
        let onDoubleTap: () -> Void

        init(value: Binding<Double>, onDoubleTap: @escaping () -> Void) {
            _value = value
            self.onDoubleTap = onDoubleTap
        }

        @objc func valueChanged(_ sender: NSSlider) {
            value = sender.doubleValue
        }
    }
}
