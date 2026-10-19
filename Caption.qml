import QtQuick
import qs.Commons

// Small-caps field label used in the editors.
Text {
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  textFormat: Text.PlainText
  color: Qt.darker(foreground, 1.5)
  font.family: fontFamily
  font.pixelSize: Style.font.caption
  font.letterSpacing: 1
  font.bold: true
}
