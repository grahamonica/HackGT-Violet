import SwiftUI

enum VioletDesign {
  static let accent = Color(red: 155 / 255, green: 130 / 255, blue: 232 / 255)
  static let deepAccent = Color(red: 59 / 255, green: 38 / 255, blue: 122 / 255)
  static let ink = Color(red: 35 / 255, green: 35 / 255, blue: 36 / 255)
  static let muted = Color(red: 100 / 255, green: 98 / 255, blue: 107 / 255)
  static let softFill = Color(red: 247 / 255, green: 245 / 255, blue: 252 / 255)
  static let cornerRadius: CGFloat = 3

  static func heading(_ size: CGFloat, bold: Bool = false) -> Font {
    .custom(bold ? "Sansation-Bold" : "Sansation-Regular", size: size)
  }

  static func body(_ size: CGFloat) -> Font {
    .custom("MuktaMalar-Light", size: size)
  }
}

struct VioletPrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(VioletDesign.heading(17, bold: true))
      .foregroundStyle(.white)
      .frame(maxWidth: .infinity)
      .frame(height: 50)
      .background(configuration.isPressed ? VioletDesign.deepAccent : VioletDesign.accent)
      .clipShape(RoundedRectangle(cornerRadius: VioletDesign.cornerRadius))
  }
}

struct VioletTextFieldStyle: TextFieldStyle {
  func _body(configuration: TextField<Self._Label>) -> some View {
    configuration
      .font(VioletDesign.body(18))
      .foregroundStyle(VioletDesign.ink)
      .padding(.horizontal, 12)
      .frame(height: 48)
      .background(VioletDesign.softFill)
      .clipShape(RoundedRectangle(cornerRadius: VioletDesign.cornerRadius))
  }
}

