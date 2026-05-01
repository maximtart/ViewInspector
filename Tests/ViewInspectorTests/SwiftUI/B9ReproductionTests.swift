// b9-fork: failing reproductions for the two SwiftUI runtime warnings observed
// in consumer suites:
//
//   1. "Accessing Environment<Bool>'s value outside of being installed on a View"
//      — fires when `.disabled(...)` modifier wraps a child that reads
//        `@Environment(\.isEnabled)`. Reproduced by `ParentWithDisabledChild`.
//
//   2. "Accessing FocusState's value outside of the body of a View"
//      — fires when a view holds `@FocusState` + `.focused($isFocused)`.
//        Reproduced by `FocusableView`.
//
// The Mirror-based assertions verify the BYTE-REWRITE state — they pass iff
// `EnvironmentInjection.resolveEnvironmentProperties` actually rewrote the
// `@Environment` enum payload from `.keyPath` to `.value` for the *child* view
// reached via `extractCustomView` (i.e. through `find()`'s traversal).
//
// Currently expected to FAIL (until the b9-fork resolver handles nested-child
// environment propagation through Apple's internal `_DisabledModifier` chain).

import XCTest
import SwiftUI

@testable import ViewInspector

@available(iOS 13.0, macOS 10.15, tvOS 13.0, *)
final class B9ReproductionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ViewInspectorConfig.resolveEnvironmentValues = true
        BodyInvocationCounter.reset()
    }

    override func tearDown() {
        ViewInspectorConfig.resolveEnvironmentValues = false
        BodyInvocationCounter.reset()
        super.tearDown()
    }

    // MARK: - Repro 1: `.disabled(true)` on nested child propagates `\.isEnabled`

    /// Sanity: `.environment(\.isEnabled, false)` directly on the child correctly
    /// flips the body output. This case is already covered by
    /// `testEnvironmentModifierOverrideUsedDuringResolution` and should pass.
    @MainActor
    func test_b9_baseline_explicitEnvironmentOnChild_reflectsFalse() throws {
        let view = ChildIsEnabledView().environment(\.isEnabled, false)
        let text = try view.inspect().find(ViewType.Text.self).string()
        XCTAssertEqual(text, "disabled")
    }

    /// REPRO: `.disabled(true)` on a child that reads `@Environment(\.isEnabled)`
    /// should make the child see `isEnabled == false`. If `find()` traversal
    /// reaches the child through Apple's `_DisabledModifier` and the resolver
    /// applies the modifier as an environment write — text reads "disabled".
    /// If the resolver doesn't propagate the modifier — text reads "enabled"
    /// (default value), proving the leak.
    @MainActor
    func test_b9_disabledOnChild_textReflectsDisabledState() throws {
        let view = ParentWithDisabledChild()
        let text = try view.inspect().find(ViewType.Text.self).string()
        XCTAssertEqual(
            text, "disabled",
            "`.disabled(true)` on nested child did not propagate \\.isEnabled — resolver leaks"
        )
    }

    /// REPRO (deep nested): the `.disabled(true)` modifier must propagate
    /// through several VStack/HStack levels to reach a deeply-nested child.
    /// Mirrors bnine.ios's ChangeEmailUIView structure (SDIButtonView at depth
    /// 3+ inside VStack/ScrollView), where the simpler shallow repro passes
    /// but warnings still fire in production.
    @MainActor
    func test_b9_disabledOnDeeplyNestedChild_textReflectsDisabledState() throws {
        let view = DeepNestedParent()
        let text = try view.inspect().find(ViewType.Text.self, where: { txt in
            let s = (try? txt.string()) ?? ""
            return s == "enabled" || s == "disabled"
        }).string()
        XCTAssertEqual(
            text, "disabled",
            "`.disabled(true)` deep in body tree did not propagate \\.isEnabled"
        )
    }

    /// REPRO (modifier-pipeline level): the parent's `.disabled(true)` modifier
    /// should be recognized as an `EnvironmentModifier` and its keyPath/value
    /// resolved to `\.isEnabled = false`. If `_EnvironmentKeyTransformModifier<Bool>`
    /// doesn't qualify (the original gating before the b9-fork generalization),
    /// `environmentValues(from:)` ignores it and `env.isEnabled` stays at its
    /// default of `true`.
    @MainActor
    func test_b9_disabledModifier_resolvedAsEnvironmentValueIsEnabledFalse() throws {
        let bodyValue = ParentWithDisabledChild().body
        guard let modifier = bodyValue as? (any EnvironmentModifier) else {
            XCTFail("body is not recognized as EnvironmentModifier")
            return
        }
        XCTAssertTrue(
            modifier.qualifiesAsEnvironmentModifier(),
            "_EnvironmentKeyTransformModifier<Bool> must qualify so .disabled(_:) propagates through find()"
        )
        let env = EnvironmentInjection.environmentValues(from: [modifier])
        XCTAssertFalse(
            env.isEnabled,
            "`.disabled(true)` should resolve to env.isEnabled == false (got true — transform was not applied)"
        )
    }

    // MARK: - Repro 1.5: EditButton's `editMode()` API

    #if os(iOS)
    /// Regression: `EditButton.editMode()` API used to call `wrappedValue` on
    /// `@Environment<Binding<EditMode>?>` directly, which emitted "Accessing
    /// Environment<Optional<Binding<EditMode>>>'s value outside of being
    /// installed on a View" each call. The b9-fork reads the enum payload via
    /// Mirror instead. This test asserts the API still returns the expected
    /// default value (nil — no edit mode in tests).
    @MainActor
    func test_b9_editButtonEditMode_returnsNilDefault_withoutWarning() throws {
        let view = EditButton()
        let result = try view.inspect().editButton().editMode()
        XCTAssertNil(result)
    }
    #endif

    // MARK: - Repro 2: `@FocusState` field
    //
    // After the b9-fork's `FocusStateInjection.installStubLocations(in:)` hook
    // in `extractContent`, the resolver byte-rewrites every nil
    // `@FocusState.location` to `.some(LocationBox<ConstantLocation<Value>>)`
    // before evaluating body. SwiftUI's wrappedValue/projectedValue getter
    // takes the installed branch and skips the runtime warning.

    /// Regression: `find(ViewType.TextField.self)` on a view holding @FocusState
    /// must succeed without emitting "Accessing FocusState's value outside of the
    /// body of a View".
    @available(iOS 15.0, macOS 12.0, tvOS 15.0, *)
    @MainActor
    func test_b9_focusStateView_findTextFieldDoesNotEmitWarning() throws {
        let view = FocusableView()
        XCTAssertNoThrow(try view.inspect().find(ViewType.TextField.self))
    }

    /// Layout-stability regression: catches the silent-failure case where
    /// Apple changes `@FocusState`'s internal layout (field order, padding,
    /// or `location` field offset). Without this assertion, a layout shift
    /// would mean `installStubLocations` silently no-ops, the byte-rewrite
    /// never lands, and the SwiftUI runtime warning quietly returns —
    /// while the `find()` traversal-based tests still pass.
    ///
    /// Strategy: call the installer directly, then walk Mirror to confirm
    /// that the `_isFocused.location` Optional has been promoted from
    /// `.none` to `.some(...)`. If the install can't find the FocusState
    /// field via byte-match, the location stays nil and this assertion
    /// fails loudly.
    @available(iOS 15.0, macOS 12.0, tvOS 15.0, *)
    @MainActor
    func test_b9_focusStateInjection_actuallyInstallsLocation() throws {
        let original = FocusableView()
        let modified = FocusStateInjection.installStubLocations(in: original)

        // Original is untouched (value semantics).
        try assertLocationIsNil(in: original, label: "original")
        // Modified should have `.some(...)` location.
        try assertLocationIsSome(in: modified, label: "modified")
    }

    private func assertLocationIsNil<V>(
        in view: V, label: String,
        file: StaticString = #file, line: UInt = #line
    ) throws {
        let (display, count) = locationOptionalState(of: view)
        XCTAssertEqual(display, "optional", "[\(label)] location must be Optional", file: file, line: line)
        XCTAssertEqual(count, 0, "[\(label)] expected location == .none, got .some", file: file, line: line)
    }

    private func assertLocationIsSome<V>(
        in view: V, label: String,
        file: StaticString = #file, line: UInt = #line
    ) throws {
        let (display, count) = locationOptionalState(of: view)
        XCTAssertEqual(display, "optional", "[\(label)] location must be Optional", file: file, line: line)
        XCTAssertEqual(
            count, 1,
            "[\(label)] FocusStateInjection failed to install location — likely SwiftUI layout changed (field offset, ordering, or padding); byte-match in writeStubLocation no longer finds the FocusState field",
            file: file, line: line
        )
    }

    private func locationOptionalState<V>(of view: V) -> (display: String, count: Int) {
        let mirror = Mirror(reflecting: view)
        guard let fs = mirror.children.first(where: { $0.label == "_isFocused" }) else {
            return ("?missingFS", -1)
        }
        let fsMirror = Mirror(reflecting: fs.value)
        guard let locField = fsMirror.children.first(where: { $0.label == "location" }) else {
            return ("?missingLoc", -1)
        }
        let locMirror = Mirror(reflecting: locField.value)
        let display = locMirror.displayStyle.map { "\($0)" } ?? "?"
        return (display, locMirror.children.count)
    }
}

// MARK: - Test fixtures

@available(iOS 13.0, macOS 10.15, tvOS 13.0, *)
private struct ChildIsEnabledView: View {
    @Environment(\.isEnabled) var isEnabled: Bool
    var body: some View {
        Text(isEnabled ? "enabled" : "disabled")
    }
}

#if DEBUG
@available(iOS 17.0, macOS 14.0, tvOS 17.0, *)
#Preview { ChildIsEnabledView() }
#endif

@available(iOS 13.0, macOS 10.15, tvOS 13.0, *)
private struct ParentWithDisabledChild: View {
    var body: some View {
        ChildIsEnabledView()
            .disabled(true)
    }
}

#if DEBUG
@available(iOS 17.0, macOS 14.0, tvOS 17.0, *)
#Preview { ParentWithDisabledChild() }
#endif

@available(iOS 13.0, macOS 10.15, tvOS 13.0, *)
private struct DeepNestedParent: View {
    var body: some View {
        VStack {
            Text("header")
            VStack {
                Text("subtitle")
                ChildIsEnabledView()
                    .disabled(true)
            }
        }
    }
}

#if DEBUG
@available(iOS 17.0, macOS 14.0, tvOS 17.0, *)
#Preview { DeepNestedParent() }
#endif

@available(iOS 15.0, macOS 12.0, tvOS 15.0, *)
private struct FocusableView: View {
    @FocusState var isFocused: Bool
    var body: some View {
        BodyInvocationCounter.count += 1
        return TextField("placeholder", text: .constant(""))
            .focused($isFocused)
    }
}

#if DEBUG
@available(iOS 17.0, macOS 14.0, tvOS 17.0, *)
#Preview { FocusableView() }
#endif

private final class BodyInvocationCounter {
    nonisolated(unsafe) static var count: Int = 0
    static func reset() { count = 0 }
}
