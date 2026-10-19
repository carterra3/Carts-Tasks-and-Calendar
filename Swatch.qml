import QtQuick
import qs.Commons

// Calendar color chip: filled when the calendar is shown, outlined when hidden.
Rectangle {
  id: root
  property color swatch: Color.accent
  property bool filled: true
  property bool ring: false
  property color ringColor: Color.foreground

  width: Style.space(12)
  height: width
  radius: Style.cornerRadius > 0 ? width / 2 : Style.space(2)
  color: filled ? swatch : "transparent"
  border.width: filled ? 0 : Math.max(1, Style.space(2))
  border.color: swatch

  Rectangle {
    visible: root.ring
    anchors.centerIn: parent
    width: root.width + Style.space(6)
    height: width
    radius: Style.cornerRadius > 0 ? width / 2 : Style.space(3)
    color: "transparent"
    border.width: Math.max(1, Style.space(2))
    border.color: root.ringColor
  }
}
