import MetalKit

final class EDRTriggerRenderer: NSObject, MTKViewDelegate {
    private let queue: MTLCommandQueue

    init?(device: MTLDevice) {
        guard let q = device.makeCommandQueue() else { return nil }
        self.queue = q
        super.init()
    }

    func mtkView(_ v: MTKView, drawableSizeWillChange s: CGSize) {}

    func draw(in view: MTKView) {
        guard let desc = view.currentRenderPassDescriptor,
              let buf = queue.makeCommandBuffer(),
              let enc = buf.makeRenderCommandEncoder(descriptor: desc) else { return }
        enc.endEncoding()
        if let d = view.currentDrawable { buf.present(d) }
        buf.commit()
    }
}
