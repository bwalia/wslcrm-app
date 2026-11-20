import SwiftUI

/// Academy — courses, lessons, creators and learners.
///
/// One hand-built hub (`academy.home`, `Features/Engage/Academy/`): instructors' courses with the
/// approval queue, the native lesson editor, instructor profile, earnings and payments, platform
/// payouts, becoming an instructor, and the learner's side (My learning, joining and studying).
/// Everything is pushed from the hub with closure links, so only the hub is a screen id.
extension ModuleGroup {
    static let engageAcademy = ModuleGroup(
        id: "engage.academy",
        screens: ["academy": AcademyScreens.home],
        screen: { id in
            switch EngageArea.parts(id).screen {
            case AcademyScreens.home: AnyView(AcademyHomeView())
            case AcademyScreens.course:
                EngageArea.parts(id).argument.map { AnyView(AcademyCourseRouteView(uuid: $0)) }
            case AcademyScreens.learning: AnyView(AcademyLearningView())
            default: nil
            }
        })
}

/// The academy's screen ids (`NativeScreenRoute`), for links from elsewhere in the app.
enum AcademyScreens {
    static let home = "academy.home"
    /// One course: `EngageArea.route(AcademyScreens.course, uuid)`.
    static let course = "academy.course"
    static let learning = "academy.learning"
}

/// A course opened by id from elsewhere (works out whether the person reviews courses).
struct AcademyCourseRouteView: View {
    let uuid: String
    @Environment(SessionStore.self) private var session

    var body: some View {
        AcademyCourseDetailView(uuid: uuid, isReviewer: AcademyAccess(session).isReviewer)
    }
}
