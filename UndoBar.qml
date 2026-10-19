import QtQuick
import qs.Commons
import qs.Ui

// "Hidden “Soccer” · Undo" for a few seconds after hiding an event.
Rectangle {
  id: root

  property var store: null
  property color fg: Color.foreground
  property string fontFamily: Style.font.family

  readonly property var last: store ? store.lastHidden : null

  visible: last !== null
  width: parent ? parent.width : implicitWidth
  height: visible ? Math.max(label.implicitHeight, undoBtn.implicitHeight) + Style.space(8) : 0
  radius: Style.cornerRadius
  color: Util.alpha(Color.accent, 0.12)

  Text {
    id: label
    x: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    width: parent.width - undoBtn.width - Style.space(20)
    elide: Text.ElideRight
    textFormat: Text.PlainText
    text: root.last ? "Hid \u201c" + root.last.title + "\u201d" + (root.last.series ? " (all repeats)" : "") : ""
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  Button {
    id: undoBtn
    anchors.right: parent.right
    anchors.rightMargin: Style.space(4)
    anchors.verticalCenter: parent.verticalCenter
    text: "Undo"
    foreground: root.fg
    fontFamily: root.fontFamily
    fontSize: Style.font.bodySmall
    onClicked: root.store.undoHide()
  }
}
