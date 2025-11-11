import Foundation
import CoreImage
import AppKit

/// 渲染队列：负责接收调整参数并智能处理渲染
actor RenderQueue {
    private var pendingAdjustments: ImageAdjustments?
    private var isProcessing = false
    private var lastProcessTime: TimeInterval = 0
    private let throttleInterval: TimeInterval
    private let renderHandler: (ImageAdjustments) async -> Void

    /// 初始化渲染队列
    /// - Parameters:
    ///   - maxFPS: 最大帧率限制（0 = 不限制，30 = 30fps，60 = 60fps）
    ///   - renderHandler: 执行渲染的闭包
    init(maxFPS: Int = 0, renderHandler: @escaping (ImageAdjustments) async -> Void) {
        // 根据帧率计算节流间隔
        self.throttleInterval = maxFPS > 0 ? (1.0 / Double(maxFPS)) : 0.0
        self.renderHandler = renderHandler
    }

    /// 将新的调整参数加入队列
    func enqueue(_ adjustments: ImageAdjustments) async {
        // 总是保存最新值，自动跳过中间值
        pendingAdjustments = adjustments

        // 如果没在处理，启动队列处理
        if !isProcessing {
            await processQueue()
        }
    }

    /// 处理队列中的任务
    private func processQueue() async {
        isProcessing = true

        while let adjustments = pendingAdjustments {
            // 清空待处理项（如果在处理过程中有新值进来，会被保存）
            pendingAdjustments = nil

            // 节流检查
            if throttleInterval > 0 {
                let now = CACurrentMediaTime()
                let elapsed = now - lastProcessTime

                if elapsed < throttleInterval {
                    // 还没到节流间隔，等待
                    let waitTime = throttleInterval - elapsed
                    try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
                }
            }

            // 执行渲染
            await renderHandler(adjustments)
            lastProcessTime = CACurrentMediaTime()

            // 如果在渲染过程中有新值进来，继续处理
            // 否则退出循环
        }

        isProcessing = false
    }

    /// 取消所有待处理的任务
    func cancelPending() {
        pendingAdjustments = nil
    }
}
