import Foundation

enum AppCommand: String, CaseIterable, Codable, Hashable, Sendable {
  case export
  case undo
  case redo
  case deleteSelected
  case selectAll
  case previousImage
  case nextImage

  var title: String {
    switch self {
    case .export: "导出"
    case .undo: "撤销"
    case .redo: "重做"
    case .deleteSelected: "删除所选图片"
    case .selectAll: "全选图片"
    case .previousImage: "上一张图片"
    case .nextImage: "下一张图片"
    }
  }
}
