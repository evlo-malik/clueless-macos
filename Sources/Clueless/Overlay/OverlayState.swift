import Foundation

@MainActor
@Observable
final class OverlayState {
    var isVisible = false
    var isIncludedInCaptures = false
}
