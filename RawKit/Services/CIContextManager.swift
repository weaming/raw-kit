import CoreImage
import Foundation

// CIContext 管理器 - 使用 Actor 确保线程安全
// 集中管理所有 CIContext 实例，提供类型安全的并发访问
actor CIContextManager {
    // 单例
    static let shared = CIContextManager()

    // 主渲染 Context - 用于图像处理和渲染
    // CIContext 本身是线程安全的，可以安全地跨隔离域访问
    nonisolated(unsafe) private let renderContext: CIContext

    // 直方图计算 Context - 低优先级，无缓存
    // CIContext 本身是线程安全的，可以安全地跨隔离域访问
    nonisolated(unsafe) private let histogramContext: CIContext

    private init() {
        // 创建主渲染 Context
        var renderOptions: [CIContextOption: Any] = [
            .useSoftwareRenderer: false,
            .cacheIntermediates: true,
            .priorityRequestLow: false,
        ]

        // 使用扩展线性 sRGB 作为工作色彩空间
        if let extendedLinearSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) {
            renderOptions[.workingColorSpace] = extendedLinearSRGB
        } else if let linearSRGB = CGColorSpace(name: CGColorSpace.linearSRGB) {
            renderOptions[.workingColorSpace] = linearSRGB
        }

        #if DEBUG
            renderOptions[.name] = "RawKit-RenderContext"
        #endif

        renderContext = CIContext(options: renderOptions)

        // 创建直方图 Context
        var histogramOptions: [CIContextOption: Any] = [
            .workingColorSpace: NSNull(),
            .useSoftwareRenderer: false,
            .cacheIntermediates: false,
            .priorityRequestLow: true,
        ]

        #if DEBUG
            histogramOptions[.name] = "RawKit-HistogramContext"
        #endif

        histogramContext = CIContext(options: histogramOptions)
    }

    // 使用主渲染 Context 创建 CGImage
    func createCGImage(_ image: CIImage, from rect: CGRect) -> CGImage? {
        renderContext.createCGImage(image, from: rect)
    }

    // 使用主渲染 Context 创建 CGImage（使用默认范围）
    func createCGImage(_ image: CIImage) -> CGImage? {
        renderContext.createCGImage(image, from: image.extent)
    }

    // 使用直方图 Context 渲染到位图
    func renderHistogram(
        _ image: CIImage,
        toBitmap bitmap: UnsafeMutablePointer<Float>,
        rowBytes: Int,
        bounds: CGRect,
        format: CIFormat,
        colorSpace: CGColorSpace?
    ) {
        histogramContext.render(
            image,
            toBitmap: bitmap,
            rowBytes: rowBytes,
            bounds: bounds,
            format: format,
            colorSpace: colorSpace
        )
    }

    // 获取渲染 Context（用于需要直接访问的场景）
    nonisolated func getRenderContext() -> CIContext {
        renderContext
    }

    // 获取直方图 Context（用于需要直接访问的场景）
    nonisolated func getHistogramContext() -> CIContext {
        histogramContext
    }
}
