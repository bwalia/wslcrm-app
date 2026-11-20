import Foundation
import os

/// Descriptors made at run time for one parent record: "the features of this app", "the secrets of
/// this service", "the deliveries of this webhook". Their paths hold the parent's id
/// (`/api/v2/billing/apps/{app}/features`), so they can't be static. A screen makes one with
/// `ModuleCatalog.scoped(_:_:)` before pushing its list; the kit's list, detail and form screens then
/// find it by id like any other descriptor.
extension ModuleCatalog {
    private static let scopedStore = OSAllocatedUnfairLock<[String: ResourceDescriptor]>(initialState: [:])

    /// `base` for one parent: every `{name}` placeholder named in `values` is filled in its paths
    /// (list, item, create, update, delete, actions, list actions, reference pickers), placeholders
    /// for the record itself (`{uuid}`) are left for the kit. The id gets the parent's values so two
    /// parents never share a list.
    @discardableResult
    static func scoped(_ base: ResourceDescriptor, _ values: [String: String], title: String? = nil) -> ResourceDescriptor {
        let suffix = values.sorted { $0.key < $1.key }.map(\.value).joined(separator: ",")
        func fill(_ path: String) -> String {
            var result = path
            for (key, value) in values {
                let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
                result = result.replacingOccurrences(of: "{\(key)}", with: encoded)
            }
            return result
        }
        func fill(_ path: String?) -> String? { path.map { fill($0) } }
        func fill(_ field: FieldSpec) -> FieldSpec {
            guard case .reference(var spec) = field.kind else { return field }
            spec = ReferenceSpec(list: fill(spec.list), valueKey: spec.valueKey, titleKeys: spec.titleKeys,
                                 subtitleKeys: spec.subtitleKeys, displayKey: spec.displayKey,
                                 searchParam: spec.searchParam, paging: spec.paging, listKey: spec.listKey)
            var copy = field
            copy.kind = .reference(spec)
            return copy
        }
        func fill(_ action: ActionSpec) -> ActionSpec {
            var copy = action
            copy.path = fill(action.path)
            copy.inputs = action.inputs.map { fill($0) }
            return copy
        }

        var api = base.api
        api.list = fill(api.list)
        api.item = fill(api.item)
        api.create = fill(api.create)
        api.update = fill(api.update)
        api.delete = fill(api.delete)
        var form = base.form
        form?.sections = base.form?.sections.map { SectionSpec($0.title, $0.fields.map { fill($0) }, footer: $0.footer) } ?? []

        let descriptor = ResourceDescriptor(
            id: "\(base.id)@\(suffix)", title: title ?? base.title, noun: base.noun, systemImage: base.systemImage,
            api: api, permissions: base.permissions, list: base.list, detail: base.detail, form: form,
            actions: base.actions.map { fill($0) }, related: base.related, summary: base.summary,
            singleton: base.singleton, writableWhen: base.writableWhen, listActions: base.listActions.map { fill($0) },
            links: base.links)
        scopedStore.withLock { $0[descriptor.id] = descriptor }
        return descriptor
    }

    /// A descriptor registered by `scoped(_:_:)`, or nil.
    static func scopedDescriptor(_ id: String) -> ResourceDescriptor? {
        scopedStore.withLock { $0[id] }
    }
}
