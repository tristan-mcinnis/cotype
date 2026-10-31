import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import CotypeCore
import CotypeMacOS
import HouseDesign
import HouseUIKit

// MARK: - Outcome presentation helpers

func outcomeIcon(for outcome: PersonalizationOutcome) -> String {
    switch outcome {
    case .accepted: return "checkmark.circle.fill"
    case .dismissed: return "xmark.circle.fill"
    case .shown: return "eye.fill"
    case .canceled: return "minus.circle.fill"
    case .failed: return "exclamationmark.triangle.fill"
    }
}

func outcomeTint(for outcome: PersonalizationOutcome) -> Color {
    switch outcome {
    case .accepted: return House.ColorToken.success
    case .dismissed: return House.ColorToken.warning
    case .shown: return House.ColorToken.textTertiary
    case .canceled: return House.ColorToken.textTertiary
    case .failed: return House.ColorToken.warning
    }
}

func outcomeLabel(for outcome: PersonalizationOutcome) -> String {
    switch outcome {
    case .accepted: return "Accepted"
    case .dismissed: return "Dismissed"
    case .shown: return "Offered"
    case .canceled: return "Canceled"
    case .failed: return "Failed"
    }
}

