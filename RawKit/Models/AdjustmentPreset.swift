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

    // 用于覆盖已有预设（保留原 ID 和创建时间）
    init(id: UUID, name: String, adjustments: ImageAdjustments, createdAt: Date) {
        self.id = id
        self.name = name
        self.adjustments = adjustments
        self.createdAt = createdAt
    }
}
