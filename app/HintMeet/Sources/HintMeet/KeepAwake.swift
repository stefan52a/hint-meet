import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// Houdt de Mac wakker zolang de telefoon-companion aan staat en de Mac aan de stroom hangt: de telefoon moet
/// hem altijd kunnen bereiken. Op de accu niet, dan beslist macOS zelf (en de telefoon slaat alarm).
final class KeepAwake {
    private var assertion: IOPMAssertionID = 0
    private var held = false

    static var onACPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return (type as String) == kIOPMACPowerKey
    }

    func update(enabled: Bool) {
        let want = enabled && Self.onACPower
        if want && !held {
            held = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                               IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                               "HintMeet phone companion" as CFString, &assertion) == kIOReturnSuccess
        } else if !want && held {
            IOPMAssertionRelease(assertion)
            held = false
        }
    }

    deinit { if held { IOPMAssertionRelease(assertion) } }
}
