import QtQuick
import QtQuick.Controls as Controls
import qs.Commons
import qs.Ui

// Multi-line text input styled like qs.Ui TextField (notes, street
// addresses). Enter makes a new line; the surrounding form's Enter-to-save
// never sees it.
Controls.TextArea {
  id: root

  property color foreground: Color.foreground
  property color accent: Color.accent
  readonly property var _borderSpec: Border.controlSpec(activeFocus ? "focus" : (hovered ? "hover-cursor" : "normal"), root.foreground, root.accent)

  wrapMode: TextEdit.Wrap
  font.family: Style.font.family
  font.pixelSize: Style.font.body
  color: foreground
  selectionColor: Style.selectionFillFor(foreground, accent)
  selectedTextColor: foreground
  placeholderTextColor: Qt.darker(foreground, 1.6)
  leftPadding: Style.spacing.controlPaddingX + Border.left(_borderSpec)
  rightPadding: Style.spacing.controlPaddingX + Border.right(_borderSpec)
  topPadding: Style.spacing.inputPaddingY + Border.top(_borderSpec)
  bottomPadding: Style.spacing.inputPaddingY + Border.bottom(_borderSpec)

  background: BorderSurface {
    color: Style.controlFill(root.activeFocus, root.hovered, root.foreground, root.accent)
    borderSpec: root._borderSpec
    radius: Style.cornerRadius
  }
}
