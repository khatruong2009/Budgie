import SwiftUI
import UIKit

extension Color {
    init(hex: UInt32) { self.init(uiColor: UIColor(hex: hex)) }
}

extension UIColor {
    /// `hex` is 0xRRGGBB, or 0xAARRGGBB when `alpha` is true.
    convenience init(hex: UInt32, alpha: Bool = false) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha ? CGFloat((hex >> 24) & 0xFF) / 255 : 1)
    }
}
