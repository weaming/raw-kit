import SwiftUI

// 操作历史面板
struct HistoryPanel: View {
    let history: AdjustmentHistory
    @Binding var adjustments: ImageAdjustments

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if history.states.isEmpty {
                Text("暂无操作历史")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                ForEach(Array(history.states.enumerated()), id: \.offset) { index, state in
                    HistoryItemView(
                        index: index,
                        isCurrent: index == history.currentStateIndex,
                        state: state,
                        onTap: {
                            history.jumpTo(index: index)
                            if let newState = history.current() {
                                adjustments = newState
                            }
                        }
                    )
                }
            }
        }
        .padding(.horizontal, 12)
    }
}

// 历史记录项
struct HistoryItemView: View {
    let index: Int
    let isCurrent: Bool
    let state: ImageAdjustments
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isCurrent ? Color.blue : Color.gray.opacity(0.3))
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(historyDescription)
                        .font(.caption)
                        .foregroundColor(isCurrent ? .primary : .secondary)

                    if isCurrent {
                        Text("当前状态")
                            .font(.caption2)
                            .foregroundColor(.blue)
                    }
                }

                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isCurrent ? Color.blue.opacity(0.1) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var historyDescription: String {
        var changes: [String] = []

        if state.exposure != 0 {
            changes.append("曝光\(String(format: "%.1f", state.exposure))")
        }
        if state.contrast != 1.0 {
            changes.append("对比度\(String(format: "%.1f", state.contrast))")
        }
        if state.temperature != 6500 {
            changes.append("色温\(Int(state.temperature))K")
        }
        if state.saturation != 1.0 {
            changes.append("饱和度\(String(format: "%.1f", state.saturation))")
        }
        if state.rotation != 0 {
            changes.append("旋转\(state.rotation)°")
        }

        if changes.isEmpty {
            return "初始状态"
        } else if changes.count == 1 {
            return changes[0]
        } else {
            return "\(changes.count) 项调整"
        }
    }
}
