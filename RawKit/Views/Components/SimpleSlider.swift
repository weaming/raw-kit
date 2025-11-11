import SwiftUI

/// 简化的滑块控件（无刻度，无重置按钮）
struct SimpleSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let valueFormatter: (Double) -> String

    init(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double> = 0.0...1.0,
        step: Double = 0.01,
        valueFormatter: @escaping (Double) -> String = { String(format: "%.2f", $0) }
    ) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
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

            Slider(
                value: Binding(
                    get: { value },
                    set: { newValue in
                        let steppedValue = round(newValue / step) * step
                        value = steppedValue
                    }
                ),
                in: range
            )
            .controlSize(.small)
        }
    }
}
