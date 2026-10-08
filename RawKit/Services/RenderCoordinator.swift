import CoreGraphics
import Foundation

enum RenderSlot: Hashable, Sendable {
  case main
  case before
  case thumbnail(UUID)
  case prefetch(UUID)
}

struct RenderKey: Hashable, Sendable {
  let imageID: UUID
  let adjustmentDigest: UInt64
  let viewportWidth: Int
  let viewportHeight: Int
  let isCropPreview: Bool

  init(
    imageID: UUID,
    adjustments: ImageAdjustments,
    viewportSize: CGSize,
    isCropPreview: Bool
  ) {
    self.imageID = imageID
    adjustmentDigest = Self.digest(adjustments)
    viewportWidth = Self.bucket(viewportSize.width)
    viewportHeight = Self.bucket(viewportSize.height)
    self.isCropPreview = isCropPreview
  }

  private static func bucket(_ value: CGFloat) -> Int {
    Int(max(value, 0).rounded(.toNearestOrAwayFromZero))
  }

  private static func digest(_ adjustments: ImageAdjustments) -> UInt64 {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    guard let data = try? encoder.encode(adjustments) else {
      return 0
    }

    var digest: UInt64 = 1_469_598_103_934_665_603
    for byte in data {
      digest ^= UInt64(byte)
      digest = digest &* 1_099_511_628_211
    }
    return digest
  }
}

actor RenderCoordinator<Request: Sendable> {
  private struct PendingRequest {
    let request: Request
    let key: RenderKey
    let priority: Int
    let sequence: UInt64
  }

  private var pending: [RenderSlot: PendingRequest] = [:]
  private var isProcessing = false
  private var nextSequence: UInt64 = 0
  private let renderHandler: @Sendable (Request) async -> Void

  init(renderHandler: @escaping @Sendable (Request) async -> Void) {
    self.renderHandler = renderHandler
  }

  func enqueue(
    _ request: Request,
    key: RenderKey,
    slot: RenderSlot = .main,
    priority: Int = 0
  ) async {
    nextSequence &+= 1
    pending[slot] = PendingRequest(
      request: request,
      key: key,
      priority: priority,
      sequence: nextSequence
    )

    guard !isProcessing else { return }
    await processPending()
  }

  func cancel(slot: RenderSlot) {
    pending.removeValue(forKey: slot)
  }

  func cancelAll() {
    pending.removeAll()
  }

  func pendingKey(for slot: RenderSlot) -> RenderKey? {
    pending[slot]?.key
  }

  private func processPending() async {
    isProcessing = true
    defer { isProcessing = false }

    while let next = nextPending() {
      pending.removeValue(forKey: next.slot)
      await renderHandler(next.request.request)
    }
  }

  private func nextPending() -> (slot: RenderSlot, request: PendingRequest)? {
    guard let item = pending.min(by: { lhs, rhs in
      if lhs.value.priority != rhs.value.priority {
        return lhs.value.priority > rhs.value.priority
      }
      return lhs.value.sequence < rhs.value.sequence
    }) else {
      return nil
    }

    return (slot: item.key, request: item.value)
  }
}
