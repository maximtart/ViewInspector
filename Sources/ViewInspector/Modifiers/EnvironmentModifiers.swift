import SwiftUI

// MARK: - Environment Modifiers

@available(iOS 13.0, macOS 10.15, tvOS 13.0, *)
public extension InspectableView {

    func environment<T>(_ keyPath: WritableKeyPath<EnvironmentValues, T>) throws -> T {
        return try environment(keyPath, call: "environment(\(Inspector.typeName(type: T.self)))")
    }
}

@available(iOS 13.0, macOS 10.15, tvOS 13.0, *)
internal extension InspectableView {
    func environment<T>(_ reference: WritableKeyPath<EnvironmentValues, T>, call: String) throws -> T {
        return try environment(reference, call: call, valueType: T.self)
    }
    
    func environment<T, V>(_ reference: WritableKeyPath<EnvironmentValues, T>,
                           call: String, valueType: V.Type) throws -> V {
        guard let modifier = content.medium.environmentModifiers.last(where: { modifier in
            guard let keyPath = try? modifier.keyPath() as? WritableKeyPath<EnvironmentValues, T>
            else { return false }
            return keyPath == reference
        }) else {
            throw InspectionError.modifierNotFound(
                parent: Inspector.typeName(value: content.view), modifier: call, index: 0)
        }
        return try Inspector.cast(value: try modifier.value(), type: V.self)
    }
}

@available(iOS 13.0, macOS 10.15, tvOS 13.0, *)
internal extension Inspector {
    static func environmentKeyPath<T>(_ type: T.Type, _ value: Any) throws -> WritableKeyPath<EnvironmentValues, T> {
        return try Inspector.attribute(path: "modifier|keyPath", value: value,
                                       type: WritableKeyPath<EnvironmentValues, T>.self)
    }
}

#if swift(>=6.0)
@MainActor
#endif
@available(iOS 13.0, macOS 10.15, tvOS 13.0, *)
internal protocol EnvironmentModifier {
    static func qualifiesAsEnvironmentModifier() -> Bool
    func keyPath() throws -> Any
    func value() throws -> Any
}

@available(iOS 13.0, macOS 10.15, tvOS 13.0, *)
extension EnvironmentModifier {
    func qualifiesAsEnvironmentModifier() -> Bool {
        return Self.qualifiesAsEnvironmentModifier()
    }
}

@available(iOS 13.0, macOS 10.15, tvOS 13.0, *)
extension ModifiedContent: EnvironmentModifier where Modifier: EnvironmentModifier {
    
    static func qualifiesAsEnvironmentModifier() -> Bool {
        return Modifier.qualifiesAsEnvironmentModifier()
    }
    
    func keyPath() throws -> Any {
        return try Inspector.attribute(label: "modifier", value: self,
                                       type: Modifier.self).keyPath()
    }
    
    func value() throws -> Any {
        return try Inspector.attribute(label: "modifier", value: self,
                                       type: Modifier.self).value()
    }
}

@available(iOS 13.0, macOS 10.15, tvOS 13.0, *)
extension _EnvironmentKeyWritingModifier: EnvironmentModifier {
    
    static func qualifiesAsEnvironmentModifier() -> Bool {
        return true
    }
    
    func keyPath() throws -> Any {
        return try Inspector.attribute(label: "keyPath", value: self)
    }
    
    func value() throws -> Any {
        return try Inspector.attribute(label: "value", value: self)
    }
}

@available(iOS 13.0, macOS 10.15, tvOS 13.0, *)
extension _EnvironmentKeyTransformModifier: EnvironmentModifier {

    static func qualifiesAsEnvironmentModifier() -> Bool {
        // b9-fork: qualify ALL Value types (was: only TextInputAutocapitalization).
        // Apple's `.disabled(_:)` is implemented as `_EnvironmentKeyTransformModifier<Bool>`
        // writing `\.isEnabled` — making it qualify lets `find()` traversal carry the
        // modifier into `medium.environmentModifiers`, so nested children's
        // `@Environment(\.isEnabled)` fields get byte-rewritten by
        // `resolveEnvironmentProperties` and don't trigger the SwiftUI runtime warning
        // "Accessing Environment<Bool>'s value outside of being installed on a View".
        //
        // Caveat: a custom `.transformEnvironment(\.x) { transform }` whose transform
        // reads the OUTER chain's value (not just the default) won't be perfectly
        // resolved here — `value()` applies the transform to `EnvironmentValues()`'s
        // default for the keyPath, which matches Apple's `.disabled` semantics
        // exactly (`$0 = $0 && !disabled`, default for `\.isEnabled` is `true`).
        return true
    }

    func keyPath() throws -> Any {
        return try Inspector.attribute(label: "keyPath", value: self)
    }

    func value() throws -> Any {
        let keyPath = try Inspector.attribute(
            label: "keyPath", value: self,
            type: WritableKeyPath<EnvironmentValues, Value>.self)
        let transform = try Inspector.attribute(
            label: "transform", value: self,
            type: ((inout Value) -> Void).self)
        var current = EnvironmentValues()[keyPath: keyPath]
        transform(&current)
        return current
    }
}
