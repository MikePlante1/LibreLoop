import Foundation
import UIKit
import SwiftUI
import LoopKit
import LoopKitUI
import LibreLoop

final class LibreLoopUICoordinator: UINavigationController, CGMManagerOnboarding, CompletionNotifying {
    var cgmManagerOnboardingDelegate: CGMManagerOnboardingDelegate?
    var completionDelegate: CompletionDelegate?

    private var cgmManager: LibreLoopCGMManager?
    private let colorPalette: LoopUIColorPalette

    init(cgmManager: LibreLoopCGMManager?, colorPalette: LoopUIColorPalette) {
        self.cgmManager = cgmManager
        self.colorPalette = colorPalette
        super.init(navigationBarClass: UINavigationBar.self, toolbarClass: UIToolbar.self)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationBar.prefersLargeTitles = true
        setViewControllers([initialView()], animated: false)
    }

    private func initialView() -> UIViewController {
        if cgmManager == nil {
            let view = LibreLoopStartupView(
                didContinue: { [weak self] in self?.completeSetup() },
                didCancel: { [weak self] in
                    guard let self else { return }
                    self.completionDelegate?.completionNotifyingDidComplete(self)
                }
            )
            return DismissibleHostingController(content: view, colorPalette: colorPalette)
        } else {
            let view = LibreLoopSettingsView(
                viewModel: LibreLoopSettingsViewModel(cgmManager: cgmManager!),
                didFinish: { [weak self] in
                    guard let self else { return }
                    self.completionDelegate?.completionNotifyingDidComplete(self)
                },
                deleteCGM: { [weak self] in
                    self?.cgmManager?.notifyDelegateOfDeletion {
                        DispatchQueue.main.async {
                            guard let self = self else { return }
                            self.completionDelegate?.completionNotifyingDidComplete(self)
                            self.dismiss(animated: true)
                        }
                    }
                }
            )
            return DismissibleHostingController(content: view, colorPalette: colorPalette)
        }
    }

    private func completeSetup() {
        let manager = LibreLoopCGMManager()
        self.cgmManager = manager
        cgmManagerOnboardingDelegate?.cgmManagerOnboarding(didCreateCGMManager: manager)
        cgmManagerOnboardingDelegate?.cgmManagerOnboarding(didOnboardCGMManager: manager)
        completionDelegate?.completionNotifyingDidComplete(self)
    }
}
