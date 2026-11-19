import SwiftUI
import UIKit

private enum AppLocalizationKey: EnvironmentKey {
    static var defaultValue: AppLocalization { AppLocalization(language: AppLanguage(preference: "system")) }
}

extension EnvironmentValues {
    var appLocalization: AppLocalization {
        get { self[AppLocalizationKey.self] }
        set { self[AppLocalizationKey.self] = newValue }
    }
}

extension AppLocalization {
    var layoutDirection: LayoutDirection { language.isRightToLeft ? .rightToLeft : .leftToRight }

    func name(of location: LocationTarget) -> String {
        location.nameKey.map(text) ?? location.name
    }

    func subtitle(of location: LocationTarget) -> String {
        location.subtitleKey.map(text) ?? location.subtitle
    }
}

@MainActor
extension FeaturePreferences {
    var appLanguage: AppLanguage { AppLanguage(preference: languageCode) }
}

/// Settings uses UIKit-backed navigation and forms. Apply the direction to their hosting controller
/// as well as the SwiftUI environment so it changes while the sheet is already presented.
struct LocalizedNavigationDirection: UIViewControllerRepresentable {
    let direction: LayoutDirection

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.direction = direction
        controller.applyDirection()
    }

    final class Controller: UIViewController {
        var direction: LayoutDirection = .leftToRight

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            applyDirection()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            applyDirection()
        }

        func applyDirection() {
            let isRTL = direction == .rightToLeft
            let trait: UITraitEnvironmentLayoutDirection = isRTL ? .rightToLeft : .leftToRight
            let semantic: UISemanticContentAttribute = isRTL ? .forceRightToLeft : .forceLeftToRight
            guard let host = navigationController ?? parent?.navigationController ?? parent else { return }
            if host.traitCollection.layoutDirection != trait {
                host.traitOverrides.layoutDirection = trait
            }
            if host.view.semanticContentAttribute != semantic {
                host.view.semanticContentAttribute = semantic
                host.view.setNeedsLayout()
            }
            if let navigation = host as? UINavigationController,
               navigation.navigationBar.semanticContentAttribute != semantic {
                navigation.navigationBar.semanticContentAttribute = semantic
                navigation.navigationBar.setNeedsLayout()
            }
        }
    }
}
