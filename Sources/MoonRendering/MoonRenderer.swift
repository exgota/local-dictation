import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// Inputs to the same shader used by the live views and the deterministic captures.
public struct MoonFrame: Sendable {
    public var time: Float = 0
    public var level: Float = 0
    public var shake: Float = 0
    public var warning: Float = 0
    public var formation: Float = 1
    public var transition: Float = 0
    public var ditherRate: Float = 0
    public var loading: Float = 0
    public var download: Float = 0
    public var mode: Float = 1
    public var previousShape: Float = 0
    public var nextShape: Float = 0

    public init() {}

    func values(width: Int, height: Int) -> [Float] {
        [Float(width), Float(height), time, level, shake, warning, formation, transition,
         ditherRate, loading, download, mode, previousShape, nextShape, 0.96, 0.96, 0.95]
    }
}

public enum MoonRenderingError: Error {
    case unavailable, missingResource(String), invalidTexture(String), commandFailed(String), imageCreation
}

/// Owns the compiled pipeline and immutable maps. Construction warms the shader without opening a window.
@MainActor public final class MoonRenderer {
    public static let shared: Result<MoonRenderer, Error> = Result { try MoonRenderer() }
    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let legend: MTLTexture
    private let surface: MTLTexture
    public private(set) var submittedFrames = 0

    public init(capturesTone: Bool = false) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw MoonRenderingError.unavailable
        }
        self.device = device
        self.queue = queue
        let source = try String(contentsOf: Self.resource("Moon", extension: "metal"), encoding: .utf8)
        let options = MTLCompileOptions()
        options.fastMathEnabled = false
        if capturesTone { options.preprocessorMacros = ["MOON_CAPTURE_TONE": NSNumber(value: 1)] }
        let library = try device.makeLibrary(source: source, options: options)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "moonVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "moonFragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        legend = try Self.loadTexture("FunctionKeyLegend", width: 512, height: 512, device: device)
        surface = try Self.loadTexture("MoonSurface", width: 1024, height: 512, device: device)
        _ = try render(MoonFrame(), pixels: 2)
    }

    static func resource(_ name: String, extension suffix: String) throws -> URL {
        let bundle: Bundle
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard let directory = Bundle.main.resourceURL?.appendingPathComponent("LocalDictation_MoonRendering.bundle"),
                  let packaged = Bundle(url: directory) else { throw MoonRenderingError.missingResource(name) }
            bundle = packaged
        } else {
            bundle = .module
        }
        guard let url = bundle.url(forResource: name, withExtension: suffix, subdirectory: "Resources") else {
            throw MoonRenderingError.missingResource(name)
        }
        return url
    }

    private static func loadTexture(_ name: String, width: Int, height: Int, device: MTLDevice) throws -> MTLTexture {
        let bytes = try Data(contentsOf: resource(name, extension: "rgba"))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: true)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw MoonRenderingError.unavailable }
        var offset = 0
        try bytes.withUnsafeBytes { memory in
            for level in 0..<texture.mipmapLevelCount {
                let columns = max(1, width >> level), rows = max(1, height >> level)
                let count = columns * rows * 4
                guard offset + count <= memory.count else { throw MoonRenderingError.invalidTexture(name) }
                texture.replace(region: MTLRegionMake2D(0, 0, columns, rows), mipmapLevel: level,
                                withBytes: memory.baseAddress!.advanced(by: offset), bytesPerRow: columns * 4)
                offset += count
            }
        }
        guard offset == bytes.count else { throw MoonRenderingError.invalidTexture(name) }
        return texture
    }

    public func makeTexture(pixels: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: pixels, height: pixels, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw MoonRenderingError.unavailable }
        return texture
    }

    public func draw(_ frame: MoonFrame, into texture: MTLTexture) throws {
        guard let command = queue.makeCommandBuffer() else { throw MoonRenderingError.unavailable }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw MoonRenderingError.unavailable }
        let values = frame.values(width: texture.width, height: texture.height)
        encoder.setRenderPipelineState(pipeline)
        values.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        encoder.setFragmentTexture(legend, index: 0)
        encoder.setFragmentTexture(surface, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw MoonRenderingError.commandFailed(command.error?.localizedDescription ?? "Metal command failed")
        }
        submittedFrames += 1
    }

    public func render(_ frame: MoonFrame, pixels: Int) throws -> MoonBitmap {
        let texture = try makeTexture(pixels: pixels)
        try draw(frame, into: texture)
        return bitmap(from: texture)
    }

    public func bitmap(from texture: MTLTexture) -> MoonBitmap {
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(&bytes, bytesPerRow: texture.width * 4,
                         from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return MoonBitmap(width: texture.width, height: texture.height, bytes: bytes)
    }
}

public struct MoonBitmap: Sendable {
    public let width: Int
    public let height: Int
    public var bytes: [UInt8]

    public init(width: Int, height: Int, bytes: [UInt8]) {
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    public func image() throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw MoonRenderingError.imageCreation }
        return image
    }

    public func write(to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw MoonRenderingError.imageCreation
        }
        CGImageDestinationAddImage(destination, try image(), nil)
        guard CGImageDestinationFinalize(destination) else { throw MoonRenderingError.imageCreation }
    }
}
