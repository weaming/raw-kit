import SwiftUI

/// 简化的滑块控件（无刻度，无重置按钮）
struct SimpleSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let valueFormatter: (Double) -> String
    let defaultValue: Double

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
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Text(valueFormatter(value))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(minWidth: 35, alignment: .trailing)
                    .monospacedDigit()
            }

            SliderWithDoubleTapSmall(
                value: Binding(
                    get: { value },
                    set: { newValue in
                        let steppedValue = round(newValue / step) * step
                        value = steppedValue
                    }
                ),
                range: range,
                onDoubleTap: { value = defaultValue }
            )
        }
    }
}

// 自定义 NSSlider：禁用点击轨道跳转，只允许拖动
public class DragOnlySlider: NSSlider {
    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // 获取滑块圆点的矩形区域
        if let sliderCell = cell as? NSSliderCell {
            let knobBounds = sliderCell.knobRect(flipped: false)

            // 只有点击在滑块圆点上时才响应
            if knobBounds.contains(point) {
                super.mouseDown(with: event)
            }
            // 点击轨道时忽略事件
        } else {
            // 如果无法获取 cell，则使用默认行为
            super.mouseDown(with: event)
        }
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

    func makeNSView(context: Context) -> DragOnlySlider {
        let slider = DragOnlySlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: context.coordinator, action: #selector(Coordinator.valueChanged(_:)))
        slider.isContinuous = true
        slider.controlSize = .small

        // 添加双击手势
        let doubleClick = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleClick.numberOfClicksRequired = 2
        slider.addGestureRecognizer(doubleClick)

        return slider
    }

    func updateNSView(_ nsView: DragOnlySlider, context: Context) {
        // 只在值真正不同时才更新，避免干扰用户交互
        // 允许小的浮点误差（0.0001）
        if abs(nsView.doubleValue - value) > 0.0001 {
            nsView.doubleValue = value
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

        @objc func handleDoubleTap(_ sender: NSClickGestureRecognizer) {
            onDoubleTap()
        }
    }
}
