import SwiftUI

/// Health: hospitals and care homes, patients and their care records, and the care home dashboard
/// (OpsAPI hospital routes, RBAC module `hospital_patients`). The screens live in `Features/Health`.
extension ModuleGroup {
    static let health = ModuleGroup(
        id: "industry.health",
        descriptors: [HealthCatalog.hospitals, HealthCatalog.patients],
        screens: [
            "hospitals": HealthScreens.hospitals,
            "patients": HealthScreens.patients,
            "care_home": HealthScreens.careHome,
        ],
        screen: { id in HealthScreens.view(id) })
}

/// The health area's hand-built screens and their ids (`NativeScreenRoute`).
enum HealthScreens {
    /// Every hospital and care home; `health.hospitals:care_home` starts filtered to one type.
    static let hospitals = "health.hospitals"
    /// One hospital or care home: `health.hospital:<uuid>`.
    static let hospital = "health.hospital"
    /// Every patient; `health.patients:<hospital uuid>|<name>` only one hospital's.
    static let patients = "health.patients"
    /// One patient: `health.patient:<uuid>`.
    static let patient = "health.patient"
    static let careHome = "health.care_home"

    /// The patients of one hospital (its name, when known, titles the list).
    static func patients(hospital: String, name: String?) -> NativeScreenRoute {
        let encoded = name?.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return NativeScreenRoute(patients, "\(hospital)|\(encoded)")
    }

    @MainActor
    static func view(_ id: String) -> AnyView? {
        let (screen, parameter) = NativeScreenRoute.parts(id)
        switch screen {
        case hospitals:
            return AnyView(HealthHospitalsView(type: parameter))
        case hospital:
            guard let parameter else { return nil }
            return AnyView(HealthHospitalView(uuid: parameter))
        case patients:
            guard let parameter else { return AnyView(HealthPatientsView()) }
            let pieces = parameter.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let name = pieces.count > 1 ? pieces[1].removingPercentEncoding.flatMap { $0.isEmpty ? nil : $0 } : nil
            return AnyView(HealthPatientsView(hospital: pieces[0], hospitalName: name))
        case patient:
            guard let parameter else { return nil }
            return AnyView(HealthPatientView(uuid: parameter))
        case careHome:
            return AnyView(CareHomeDashboardView())
        default:
            return nil
        }
    }
}
