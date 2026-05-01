import SwiftUI

@available(iOS 13.0, macOS 10.15, tvOS 13.0, *)
public extension ViewType {
    
    struct EditButton: KnownViewType {
        public static let typePrefix: String = "EditButton"
    }
}

#if os(iOS)

// MARK: - Extraction from SingleViewContent parent

@available(iOS 13.0, macOS 10.15, tvOS 13.0, *)
public extension InspectableView where View: SingleViewContent {
    
    func editButton() throws -> InspectableView<ViewType.EditButton> {
        return try .init(try child(), parent: self)
    }
}

// MARK: - Extraction from MultipleViewContent parent

@available(iOS 13.0, macOS 10.15, tvOS 13.0, *)
public extension InspectableView where View: MultipleViewContent {
    
    func editButton(_ index: Int) throws -> InspectableView<ViewType.EditButton> {
        return try .init(try child(at: index), parent: self, index: index)
    }
}

// MARK: - Custom Attributes

@available(iOS 13.0, macOS 10.15, tvOS 13.0, *)
public extension InspectableView where View == ViewType.EditButton {

    func editMode() throws -> Binding<EditMode>? {
        let editMode: Any
        if let mode = try? Inspector.attribute(label: "_editMode", value: content.view) {
            editMode = mode
        } else {
            editMode = try Inspector.attribute(label: "editMode", value: content.view)
        }
        // b9-fork: walk the @Environment's `content` enum payload via Mirror
        // instead of calling `.wrappedValue`. SwiftUI's wrappedValue getter
        // emits "Accessing Environment<…>'s value outside of being installed
        // on a View" when the enum is in `.keyPath` state outside an installed
        // view — which is the steady-state during inspection. Reading the
        // payload directly preserves the original return value (default for
        // `.keyPath`, stored value for `.value`) without tripping the getter.
        return readEnvironmentBinding(from: editMode)
    }
}

@available(iOS 13.0, macOS 10.15, tvOS 13.0, *)
private func readEnvironmentBinding(from editMode: Any) -> Binding<EditMode>? {
    let mirror = Mirror(reflecting: editMode)
    guard let contentChild = mirror.children.first(where: { $0.label == "content" })
    else { return nil }
    let contentMirror = Mirror(reflecting: contentChild.value)
    guard let enumCase = contentMirror.children.first else { return nil }
    switch enumCase.label {
    case "value":
        // Associated value type is `Binding<EditMode>?` (the env value type).
        // Cast through Optional first; either branch ends up as `Binding<EditMode>?`.
        return enumCase.value as? Binding<EditMode>
    case "keyPath":
        guard let keyPath = enumCase.value as? KeyPath<EnvironmentValues, Binding<EditMode>?>
        else { return nil }
        return EnvironmentValues()[keyPath: keyPath]
    default:
        return nil
    }
}

#endif
