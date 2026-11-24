import SwiftUI

/// Screen ids of the payroll area (`NativeScreenRoute`). One record's screen carries its uuid after a colon.
enum PayrollScreens {
    /// Payroll (`/dashboard/payroll`): employers, pay runs in progress, what's owed to HMRC.
    static let home = "payroll.home"
    /// My pay (`/dashboard/my-pay`): every employee's own payslips.
    static let myPay = "payroll.my_pay"
    /// Every pay run in the workspace.
    static let runs = "payroll.runs"
    static func employer(_ uuid: String) -> String { "payroll.employer:\(uuid)" }
    static func employees(_ employer: String) -> String { "payroll.employees:\(employer)" }
    static func run(_ uuid: String) -> String { "payroll.run:\(uuid)" }
    /// A payslip for staff (any line, `payroll.read`).
    static func payslip(_ line: String) -> String { "payroll.payslip:\(line)" }
    /// One of the signed-in employee's own payslips.
    static func myPayslip(_ line: String) -> String { "payroll.my_payslip:\(line)" }
}

/// Payroll and My pay (`lapis/routes/payroll.lua`). Hand-built screens (`Features/Payroll/`): a pay run is a
/// workflow, and the figures all come from the server's engine.
extension ModuleGroup {
    static let payroll = ModuleGroup(
        id: "payroll",
        screens: ["payroll": PayrollScreens.home, "my_pay": PayrollScreens.myPay],
        screen: { id in
            let (screen, parameter) = NativeScreenRoute.parts(id)
            switch (screen, parameter) {
            case ("payroll.home", _): return AnyView(PayrollHomeView())
            case ("payroll.my_pay", _): return AnyView(MyPayView())
            case ("payroll.runs", _): return AnyView(PayrollRunsView())
            case ("payroll.employer", let uuid?): return AnyView(PayrollEmployerView(uuid: uuid))
            case ("payroll.employees", let uuid?): return AnyView(PayrollEmployeesView(employer: uuid))
            case ("payroll.run", let uuid?): return AnyView(PayrollRunView(uuid: uuid))
            case ("payroll.payslip", let line?): return AnyView(PayslipView(line: line, mine: false))
            case ("payroll.my_payslip", let line?): return AnyView(PayslipView(line: line, mine: true))
            default: return nil
            }
        })
}
