// b9-fork: install a stub `AnyLocation<Value>` instance into every nil
// `@FocusState.location` field discovered on a view via Mirror walk. This
// short-circuits the "Accessing FocusState's value outside of the body of a
// View" SwiftUI runtime warning that fires whenever ViewInspector evaluates
// a body via reflection (no real installed View context).
//
// Mechanism (verified against OpenSwiftUI source):
//   • `Binding<Value>.constant(_:)` constructs `Binding(value:, location:
//     LocationBox(ConstantLocation(...)))`. `LocationBox<L>` is declared
//     `final class LocationBox<L: Location>: AnyLocation<L.Value>` — i.e.
//     it IS-A `AnyLocation<Value>` (the type required by `FocusState.location`).
//   • SwiftUI's `FocusState.wrappedValue` getter checks `if let location { ... }
//     else { Log.runtimeIssues("Accessing FocusState's value outside ..."); ... }`.
//     A non-nil `LocationBox` makes the getter return through `location.get()`,
//     skipping the warning emission entirely.
//   • `LocationBox` overrides exactly the `get()` / `set(_:transaction:)`
//     methods SwiftUI invokes during inspection — no abstract-method dispatch
//     crashes, no closures retained (ConstantLocation is stateless).
//
// ARC: each install does one `Unmanaged.passRetained` so the Optional<class>
// field's destructor (called once when the FocusState struct is destroyed)
// nets to zero. The `LocationBox` instance is therefore released exactly when
// the parent struct dies.

import SwiftUI

// MARK: - Per-Value protocol witness

@available(iOS 15.0, macOS 12.0, tvOS 15.0, *)
internal protocol FocusStateLocationInstallable {
    /// Build a stub `AnyLocation<Value>` instance (concretely a
    /// `LocationBox<ConstantLocation<Value>>` extracted from
    /// `Binding.constant(value)`). Return value is the boxed reference,
    /// retained-but-unmanaged caller.
    func _buildStubLocation() -> AnyObject?
    /// Bytes of the `value: Value` field at the start of the FocusState
    /// struct. Used as an identifying prefix when locating the FocusState
    /// inside a parent struct (padding bytes between fields are not stable
    /// across struct copies, so we cannot match the full field).
    func _valueFieldBytes() -> [UInt8]
    /// Size of the `value: Value` field (== `MemoryLayout<Value>.size`).
    static var _valueSize: Int { get }
    /// Byte offset of `location: AnyLocation<Value>?` within the FocusState
    /// struct, computed from `Value`'s stride and pointer alignment.
    static var _locationOffsetWithinFocusState: Int { get }
    /// Total in-memory size of the FocusState struct.
    static var _focusStateSize: Int { get }
}

@available(iOS 15.0, macOS 12.0, tvOS 15.0, *)
extension FocusState: FocusStateLocationInstallable {
    func _buildStubLocation() -> AnyObject? {
        let mirror = Mirror(reflecting: self)
        guard let valueChild = mirror.children.first(where: { $0.label == "value" }),
              let seed = valueChild.value as? Value
        else { return nil }
        let constBinding = SwiftUI.Binding<Value>.constant(seed)
        let bMirror = Mirror(reflecting: constBinding)
        guard let box = bMirror.children.first(where: { $0.label == "location" })?.value
        else { return nil }
        return box as AnyObject
    }

    func _valueFieldBytes() -> [UInt8] {
        let mirror = Mirror(reflecting: self)
        guard let valueChild = mirror.children.first(where: { $0.label == "value" }),
              let typed = valueChild.value as? Value
        else { return [] }
        var local = typed
        return withUnsafeBytes(of: &local) { bytes in
            Array(bytes[0..<min(bytes.count, MemoryLayout<Value>.size)])
        }
    }

    static var _valueSize: Int { MemoryLayout<Value>.size }

    static var _locationOffsetWithinFocusState: Int {
        let pointerAlignment = MemoryLayout<AnyObject?>.alignment
        let valueStride = max(MemoryLayout<Value>.stride, 1)
        return ((valueStride + pointerAlignment - 1) / pointerAlignment) * pointerAlignment
    }

    static var _focusStateSize: Int { MemoryLayout<Self>.size }
}

// MARK: - Installer

@available(iOS 15.0, macOS 12.0, tvOS 15.0, *)
internal enum FocusStateInjection {

    /// Walks every `@FocusState<Value>` field of `entity`, and for any whose
    /// `location` Optional is currently `nil`, byte-rewrites the field bytes
    /// in place so `location == .some(stubLocation)`. Returns the modified
    /// copy; original is untouched (value semantics).
    static func installStubLocations<T>(in entity: T) -> T {
        guard ViewInspectorConfig.resolveEnvironmentValues else { return entity }

        let prefix = "SwiftUI.FocusState<"
        let mirror = Mirror(reflecting: entity)
        var copy = entity

        for (childIndex, child) in mirror.children.enumerated() {
            let typeName = Inspector.typeName(value: child.value, namespaced: true)
            guard typeName.hasPrefix(prefix) else { continue }

            // Skip if already installed (.some).
            let fsMirror = Mirror(reflecting: child.value)
            guard let locField = fsMirror.children.first(where: { $0.label == "location" })
            else { continue }
            let locMirror = Mirror(reflecting: locField.value)
            guard locMirror.displayStyle == .optional, locMirror.children.isEmpty
            else { continue }

            // Generic dispatch via protocol — gives us the right Binding<Value>,
            // typed bytes of the FocusState's value field, and field offsets.
            guard let installable = child.value as? any FocusStateLocationInstallable,
                  let stub = installable._buildStubLocation()
            else { continue }
            let installableType = type(of: installable) as any FocusStateLocationInstallable.Type
            let locationOffsetInFS = installableType._locationOffsetWithinFocusState
            let fsSize = installableType._focusStateSize
            let valueSize = installableType._valueSize
            let valueBytes = installable._valueFieldBytes()

            // Find the FocusState field's offset within `entity` using a
            // tolerant match: only the value-field bytes (offset 0 of the
            // FocusState) are stable; padding bytes between fields are not
            // copied deterministically by Mirror. Combine value-byte match
            // with a "location must currently be nil" check at offset 8 to
            // reduce false positives.
            copy = writeStubLocation(
                stub: stub,
                valueBytes: valueBytes,
                valueSize: valueSize,
                fieldSize: fsSize,
                locationOffsetInField: locationOffsetInFS,
                exactFieldOffset: _vi_recursiveChildOffset(T.self, index: childIndex),
                into: copy
            )
        }
        return copy
    }

    private static func writeStubLocation<T>(
        stub: AnyObject,
        valueBytes: [UInt8],
        valueSize: Int,
        fieldSize: Int,
        locationOffsetInField: Int,
        exactFieldOffset: Int?,
        into entity: T
    ) -> T {
        let entitySize = MemoryLayout<T>.size
        let alignment = max(MemoryLayout<T>.alignment, 1)
        let pointerSize = MemoryLayout<UnsafeMutableRawPointer?>.size

        // Prefer the exact runtime field offset — the scan below matches on the
        // FocusState's value bytes (1 byte for Bool), which false-matches inside
        // large sibling fields; same failure mode as the @Environment resolver.
        if let exact = exactFieldOffset,
           exact + fieldSize <= entitySize {
            var verified = false
            withUnsafeBytes(of: entity) { entityBytes in
                let locStart = exact + locationOffsetInField
                guard locStart + pointerSize <= entityBytes.count else { return }
                verified = entityBytes[locStart..<locStart + pointerSize].allSatisfy { $0 == 0 }
            }
            if verified {
                let retained = Unmanaged.passRetained(stub).toOpaque()
                var result = entity
                withUnsafeMutableBytes(of: &result) { bytes in
                    let dst = bytes.baseAddress!.advanced(by: exact + locationOffsetInField)
                    dst.assumingMemoryBound(to: UnsafeMutableRawPointer?.self).pointee = retained
                }
                return result
            }
        }

        var offset = 0
        while offset + fieldSize <= entitySize {
            var matches = false
            withUnsafeBytes(of: entity) { entityBytes in
                // Match the FocusState's `value: Value` field bytes at offset 0
                // of the candidate field. Padding bytes between fields are NOT
                // copied deterministically by Mirror (memcpy of `Any`-extracted
                // struct copies sees random uninitialized padding), so a full-
                // field byte match is unreliable — but the value field itself
                // is stable.
                guard offset + valueSize <= entityBytes.count,
                      offset + locationOffsetInField + pointerSize <= entityBytes.count
                else { return }
                let valueSlice = Array(entityBytes[offset..<offset + valueSize])
                guard valueSlice == valueBytes else { return }
                // Confirm by checking that the `location: AnyLocation<Value>?`
                // slot at the expected offset is currently `nil` (8 zero bytes).
                // Reduces false positives when value bytes happen to match an
                // unrelated field starting at a different offset.
                let locStart = offset + locationOffsetInField
                let locSlice = Array(entityBytes[locStart..<locStart + pointerSize])
                matches = locSlice.allSatisfy { $0 == 0 }
            }

            if matches {
                let retained = Unmanaged.passRetained(stub).toOpaque()
                var result = entity
                withUnsafeMutableBytes(of: &result) { bytes in
                    let dst = bytes.baseAddress!.advanced(by: offset + locationOffsetInField)
                    dst.assumingMemoryBound(to: UnsafeMutableRawPointer?.self).pointee = retained
                }
                return result
            }
            offset += alignment
        }
        return entity
    }
}
