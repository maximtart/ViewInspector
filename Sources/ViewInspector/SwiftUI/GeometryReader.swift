import SwiftUI

@available(iOS 13.0, macOS 10.15, tvOS 13.0, *)
public extension ViewType {
    
    struct GeometryReader: KnownViewType {
        public static let typePrefix: String = "GeometryReader"
    }
}

// MARK: - Content Extraction

@available(iOS 13.0, macOS 10.15, tvOS 13.0, *)
extension ViewType.GeometryReader: SingleViewContent {
    
    public static func child(_ content: Content) throws -> Content {
        let provider = try Inspector.cast(value: content.view, type: SingleViewProvider.self)
        let medium = content.medium.resettingViewModifiers()
        return try Inspector.unwrap(view: provider.view(), medium: medium)
    }
}

// MARK: - Extraction from SingleViewContent parent

@available(iOS 13.0, macOS 10.15, tvOS 13.0, *)
public extension InspectableView where View: SingleViewContent {
    
    func geometryReader() throws -> InspectableView<ViewType.GeometryReader> {
        return try .init(try child(), parent: self)
    }
}

// MARK: - Extraction from MultipleViewContent parent

@available(iOS 13.0, macOS 10.15, tvOS 13.0, *)
public extension InspectableView where View: MultipleViewContent {
    
    func geometryReader(_ index: Int) throws -> InspectableView<ViewType.GeometryReader> {
        return try .init(try child(at: index), parent: self, index: index)
    }
}

// MARK: - Private

@available(iOS 13.0, macOS 10.15, tvOS 13.0, *)
extension GeometryReader: SingleViewProvider {
    func view() throws -> Any {
        typealias Builder = (GeometryProxy) -> Content
        let builder = try Inspector
            .attribute(label: "content", value: self, type: Builder.self)
        return builder(GeometryProxy())
    }
}

@available(iOS 13.0, macOS 10.15, tvOS 13.0, *)
private extension GeometryProxy {
    // Zero-filled stand-in; size varies by SDK (48/52 pre-27, 76 on SDK 27).
    init() {
        let size = MemoryLayout<GeometryProxy>.size
        let zeros = [UInt8](repeating: 0, count: size)
        self = zeros.withUnsafeBytes {
            $0.baseAddress!.loadUnaligned(as: GeometryProxy.self)
        }
    }
}
