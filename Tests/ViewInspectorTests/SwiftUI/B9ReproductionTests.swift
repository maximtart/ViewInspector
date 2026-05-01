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

    // MARK: - Repro 2: `@FocusState` field

    /// REPRO: inspecting a view that holds `@FocusState` + `.focused($state)` —
    /// the body should NOT be evaluated more than ~once for a simple `.find()`
    /// call. Each body evaluation outside an installed View context emits a
    /// SwiftUI runtime warning. This counter-based assertion is a proxy for
    /// "no warnings emitted".
    ///
    /// Currently expected to FAIL: the body re-evaluates multiple times during
    /// reflection traversal because @FocusState wrappedValue access can't be
    /// pre-resolved with the same byte-rewrite trick used for @Environment.
    @available(iOS 15.0, macOS 12.0, tvOS 15.0, *)
    @MainActor
    func test_b9_focusStateView_bodyEvaluatedAtMostTwice() throws {
        let view = FocusableView()
        _ = try view.inspect().find(ViewType.TextField.self)

        XCTAssertLessThanOrEqual(
            BodyInvocationCounter.count, 2,
            "FocusableView.body evaluated \(BodyInvocationCounter.count) times during inspection — each evaluation outside an installed View emits a FocusState runtime warning"
        )
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
