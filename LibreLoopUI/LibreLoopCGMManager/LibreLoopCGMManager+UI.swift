import Foundation
import SwiftUI
import HealthKit
import LoopKit
import LoopKitUI
import LibreLoop

extension LibreLoopCGMManager: CGMManagerUI {
    public static var onboardingImage: UIImage? { nil }

    public static func setupViewController(
        bluetoothProvider: BluetoothProvider,
        displayGlucosePreference: DisplayGlucosePreference,
        colorPalette: LoopUIColorPalette,
        allowDebugFeatures: Bool,
        prefersToSkipUserInteraction: Bool
    ) -> SetupUIResult<CGMManagerViewController, CGMManagerUI> {
        .userInteractionRequired(LibreLoopUICoordinator(cgmManager: nil, colorPalette: colorPalette))
    }

    public func settingsViewController(
        bluetoothProvider: BluetoothProvider,
        displayGlucosePreference: DisplayGlucosePreference,
        colorPalette: LoopUIColorPalette,
        allowDebugFeatures: Bool
    ) -> CGMManagerViewController {
        LibreLoopUICoordinator(cgmManager: self, colorPalette: colorPalette)
    }

    public var smallImage: UIImage? { nil }

    public var cgmStatusHighlight: DeviceStatusHighlight? { nil }
    public var cgmStatusBadge: DeviceStatusBadge? { nil }
    public var cgmLifecycleProgress: DeviceLifecycleProgress? { nil }

    public func glucoseRangeCategory(for glucose: GlucoseSampleValue) -> GlucoseRangeCategory? { nil }

    public func unitDidChange(to displayGlucoseUnit: HKUnit) { }
}
