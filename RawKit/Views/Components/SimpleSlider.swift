import SwiftUI

/// 简化的滑块控件（无刻度，无重置按钮）
struct SimpleSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let valueFormatter: (Double) -> String
    let defaultValue: Double
    @State private var displayValue: Double

    init(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double> = 0.0...1.0,
        step: Double = 0.01,
        defaultValue: Double = 1.0,
        valueFormatter: @escaping (Double) -> String = { String(format: "%.2f", $0) }
    ) {
        self.title = title
        self._value = value
        self.range = range
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

            SliderWithDoubleTapSmall(
                value: Binding(
                    get: { displayValue },
                    set: handleDisplayValueChange
                ),
                range: range,
                onDoubleTap: resetToDefault
            )
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
    }

    private func handleDisplayValueChange(_ newValue: Double) {
        let steppedValue = clamp(round(newValue / step) * step, to: range)
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

    private func resetToDefault() {
        displayValue = defaultValue
        let binding = _value
        DispatchQueue.main.async {
            binding.wrappedValue = defaultValue
        }
    }
}

// 自定义 NSSlider：点击轨道时立即跳到目标值，并保留原生拖动行为
public final class TrackClickableSlider: NSSlider {
    public var onDoubleClick: (() -> Void)?

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
        doubleValue = value(at: point, knobRect: knobRect)
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
}

// 小尺寸的支持双击重置的滑块
struct SliderWithDoubleTapSmall: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let onDoubleTap: () -> Void

    init(value: Binding<Double>, range: ClosedRange<Double>, onDoubleTap: @escaping () -> Void) {
        self._value = value
        self.range = range
        self.onDoubleTap = onDoubleTap
    }

    func makeNSView(context: Context) -> TrackClickableSlider {
        let slider = TrackClickableSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: context.coordinator, action: #selector(Coordinator.valueChanged(_:)))
        slider.isContinuous = true
        slider.controlSize = .small
        slider.onDoubleClick = onDoubleTap

        return slider
    }

    func updateNSView(_ nsView: TrackClickableSlider, context: Context) {
        nsView.minValue = range.lowerBound
        nsView.maxValue = range.upperBound
        nsView.onDoubleClick = onDoubleTap

        // 只在值真正不同时才更新，避免干扰用户交互
        // 允许小的浮点误差（0.0001）
        let clampedValue = min(max(value, range.lowerBound), range.upperBound)
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
