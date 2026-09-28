import Foundation
import CoreImage
import CoreVideo
import Metal
import simd

@MainActor
final class RobotVideoOptics {
    private struct Eye: Decodable {
        let camera_matrix: [[Float]]
        let distortion_coefficients: [Float]
        let rectification_rotation: [[Float]]
    }

    private struct Profile: Decodable {
        let schema: String
        let image_size: [Int]
        let source_calibration_sha256: String
        let baseline_m: Float
        let left: Eye
        let right: Eye
    }

    private struct Parameters {
        var inverseRectification: simd_float4x4
        var intrinsics: SIMD4<Float>
        var distortion: SIMD4<Float>
        var imageAndFocal: SIMD4<Float>
    }

    enum OpticsError: LocalizedError {
        case invalidCalibration
        case unsupportedFrame
        case unavailableGPU

        var errorDescription: String? {
            switch self {
            case .invalidCalibration: return "头部相机标定数据不可用"
            case .unsupportedFrame: return "视频尺寸与头部相机标定不匹配"
            case .unavailableGPU: return "相机校正显示资源不可用"
            }
        }
    }

    let eyeWidth: Int
    let eyeHeight: Int
    let calibrationSource: String
    let baselineM: Float
    private let staging: any MTLTexture
    private let pipeline: any MTLRenderPipelineState
    private var eyeParameters: [Parameters]
    private let colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!

    init(device: any MTLDevice, bundle: Bundle = .main) throws {
        guard let url = bundle.url(forResource: "head-optics", withExtension: "json") else {
            throw OpticsError.invalidCalibration
        }
        let profile = try JSONDecoder().decode(Profile.self, from: Data(contentsOf: url))
        let eyes = [profile.left, profile.right]
        guard profile.schema == "r1_head_optics_v1", profile.image_size.count == 2,
              profile.image_size.allSatisfy({ $0 > 0 }),
              eyes.allSatisfy({ eye in
                  eye.camera_matrix.count == 3 && eye.camera_matrix.allSatisfy { $0.count == 3 && $0.allSatisfy(\.isFinite) }
                  && eye.distortion_coefficients.count == 4 && eye.distortion_coefficients.allSatisfy(\.isFinite)
                  && eye.rectification_rotation.count == 3 && eye.rectification_rotation.allSatisfy { $0.count == 3 && $0.allSatisfy(\.isFinite) }
              }) else { throw OpticsError.invalidCalibration }
        eyeWidth = profile.image_size[0]
        eyeHeight = profile.image_size[1]
        calibrationSource = profile.source_calibration_sha256
        baselineM = profile.baseline_m
        eyeParameters = eyes.map { eye in
            let r = eye.rectification_rotation
            // The profile maps raw rays to rectified rays; sampling needs its transpose.
            let inverse = simd_float4x4(columns: (
                SIMD4(r[0][0], r[0][1], r[0][2], 0),
                SIMD4(r[1][0], r[1][1], r[1][2], 0),
                SIMD4(r[2][0], r[2][1], r[2][2], 0),
                SIMD4(0, 0, 0, 1)))
            let k = eye.camera_matrix
            let d = eye.distortion_coefficients
            return Parameters(inverseRectification: inverse,
                              intrinsics: SIMD4(k[0][0], k[1][1], k[0][2], k[1][2]),
                              distortion: SIMD4(d[0], d[1], d[2], d[3]),
                              imageAndFocal: .zero)
        }
        let texture = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
            width: eyeWidth * 2, height: eyeHeight, mipmapped: false)
        texture.storageMode = .private
        texture.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let staging = device.makeTexture(descriptor: texture) else { throw OpticsError.unavailableGPU }
        self.staging = staging
        let library = try device.makeDefaultLibrary(bundle: bundle)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "r1OpticsVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "r1OpticsFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    func supports(width: Int, height: Int) -> Bool {
        width == eyeWidth * 2 && height == eyeHeight
    }

    func encode(pixelBuffer: CVPixelBuffer, targets: [any MTLTexture], fov: Float,
                commandBuffer: any MTLCommandBuffer, context: CIContext) throws {
        guard supports(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer)) else {
            throw OpticsError.unsupportedFrame
        }
        let bounds = CGRect(x: 0, y: 0, width: eyeWidth * 2, height: eyeHeight)
        let image = CIImage(cvPixelBuffer: pixelBuffer).transformed(by:
            CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(eyeHeight)))
        context.render(image, to: staging, commandBuffer: commandBuffer, bounds: bounds, colorSpace: colorSpace)
        let focal = Float(eyeWidth) / (2 * tan(fov * .pi / 360))
        for eye in 0..<2 {
            var parameters = eyeParameters[eye]
            parameters.imageAndFocal = SIMD4(Float(eyeWidth), Float(eyeHeight), focal, Float(eye))
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = targets[eye]
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                throw OpticsError.unavailableGPU
            }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(staging, index: 0)
            encoder.setFragmentBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
    }
}
