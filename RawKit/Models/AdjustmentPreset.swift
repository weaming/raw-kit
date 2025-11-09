import Foundation

// 调整预设数据模型
struct AdjustmentPreset: Identifiable, Codable {
    let id: UUID
    let name: String
    let adjustments: ImageAdjustments
    let createdAt: Date

    init(name: String, adjustments: ImageAdjustments, createdAt: Date) {
        id = UUID()
        self.name = name
        self.adjustments = adjustments
        self.createdAt = createdAt
    }
}
