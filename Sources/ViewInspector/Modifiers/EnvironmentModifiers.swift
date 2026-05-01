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
    /// b9-fork: when `true`, the modifier should be appended to BOTH
    /// `medium.environmentModifiers` (so the resolver can propagate its
    /// keyPath/value into nested children) AND `medium.viewModifiers` (so
    /// existing ViewInspector code paths — e.g. `tap()`'s `isDisabled` check
    /// for `.disabled(_:)` — still find it there). Default `false` preserves
    /// upstream behavior for `_EnvironmentKeyWritingModifier`-style cases
    /// where viewModifiers count must stay at 0.
    static func requiresViewModifierMirror() -> Bool
    func keyPath() throws -> Any
    func value() throws -> Any
}

@available(iOS 13.0, macOS 10.15, tvOS 13.0, *)
extension EnvironmentModifier {
    func qualifiesAsEnvironmentModifier() -> Bool {
        return Self.qualifiesAsEnvironmentModifier()
    }
    static func requiresViewModifierMirror() -> Bool { return false }
    func requiresViewModifierMirror() -> Bool {
        return Self.requiresViewModifierMirror()
    }
}

@available(iOS 13.0, macOS 10.15, tvOS 13.0, *)
extension ModifiedContent: EnvironmentModifier where Modifier: EnvironmentModifier {

    static func qualifiesAsEnvironmentModifier() -> Bool {
        return Modifier.qualifiesAsEnvironmentModifier()
    }

    static func requiresViewModifierMirror() -> Bool {
        return Modifier.requiresViewModifierMirror()
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
        // b9-fork: qualify Bool (Apple's `.disabled(_:)` is
        // `_EnvironmentKeyTransformModifier<Bool>` writing `\.isEnabled`) and the
        // original TextInputAutocapitalization case. Bool qualification lets
        // `.disabled(_:)` propagate through the resolver to silence the
        // `Accessing Environment<Bool>'s value outside of being installed on a View`
        // SwiftUI runtime warning. Other Value types stay un-qualified to keep
        // upstream behavior for `.transformEnvironment(\.x) { ... }` (where the
        // transform may legitimately depend on the outer chain's value).
        if Value.self == Bool.self { return true }
        #if !os(macOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 15.0, tvOS 15.0, watchOS 8.0, *),
           Value.self == TextInputAutocapitalization.self {
            return true
        }
        #endif
        return false
    }

    static func requiresViewModifierMirror() -> Bool {
        // b9-fork: `.disabled(_:)` (Bool) must ALSO live in `medium.viewModifiers`
        // because ViewInspector's existing `tap()`/`isDisabled`/transitive-modifier
        // code paths look for `_EnvironmentKeyTransformModifier<Bool>` there. Mirror
        // it into both lists so we don't break those tests while also feeding the
        // resolver via the env list. (TextInputAutocapitalization keeps the upstream
        // env-list-only behavior.)
        return Value.self == Bool.self
    }

    func keyPath() throws -> Any {
        return try Inspector.attribute(label: "keyPath", value: self)
    }

    func value() throws -> Any {
        // b9-fork: for Bool transforms (e.g. `.disabled(_:)` writing `\.isEnabled`),
        // apply the captured transform to the keyPath's default value and return the
        // resolved Bool. This lets `EnvironmentInjection.environmentValues(from:)`
        // correctly populate `\.isEnabled = false` for child resolver byte-rewrites.
        // For all other Value types, preserve the original behavior of returning
        // the transform closure itself — existing tests (e.g. autocapitalization)
        // expect the closure for direct inspection.
        if Value.self == Bool.self {
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
        return try Inspector.attribute(label: "transform", value: self)
    }
}
