import SwiftUI

/// Screen ids of the payroll area (`NativeScreenRoute`). One record's screen carries its uuid after a colon.
enum PayrollScreens {
    /// My pay (`/dashboard/my-pay`): every employee's own payslips.
    static let myPay = "payroll.my_pay"
    static func myPayslip(_ line: String) -> String { "payroll.my_payslip:\(line)" }
}

/// Payroll and My pay (`lapis/routes/payroll.lua`). Hand-built screens (`Features/Payroll/`): a pay run is a
/// workflow, and the figures all come from the server's engine.
extension ModuleGroup {
    static let payroll = ModuleGroup(
        id: "payroll",
        screens: ["my_pay": PayrollScreens.myPay],
        screen: { id in
            let (screen, parameter) = NativeScreenRoute.parts(id)
            switch (screen, parameter) {
            case ("payroll.my_pay", _): return AnyView(MyPayView())
            case ("payroll.my_payslip", let line?): return AnyView(PayslipView(line: line, mine: true))
            default: return nil
            }
        })
}
