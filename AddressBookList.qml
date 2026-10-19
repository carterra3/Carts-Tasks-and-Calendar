import QtQuick
import qs.Commons
import qs.Ui

// Contacts sidebar: "ADDRESS BOOKS" header (sync + add), an "All contacts"
// row and one row per address book. Clicking a row filters the list to it;
// the pencil opens its settings.
Column {
  id: root

  property var store: null
  property string selectedBook: ""       // "" = all
  property color fg: Color.foreground
  property string fontFamily: Style.font.family

  signal selected(string bookId)
  signal addRequested()
  signal editRequested(var book)

  readonly property color faintFg: Qt.darker(fg, 1.9)
  readonly property var books: store ? store.addressBooks : []

  spacing: Style.space(4)

  Item {
    width: parent.width
    height: addBtn.height

    PanelSectionHeader {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: "ADDRESS BOOKS"
      foreground: root.fg
      fontFamily: root.fontFamily
    }

    Row {
      anchors.right: parent.right
      anchors.rightMargin: -Style.space(6)
      anchors.verticalCenter: parent.verticalCenter

      PanelActionButton {
        visible: root.books.length > 0
        iconText: "󰑐"
        tooltipText: root.store && root.store.contactsSyncing ? "Syncing…" : "Sync contacts"
        foreground: root.store && root.store.contactsSyncing ? root.faintFg : root.fg
        fontFamily: root.fontFamily
        enabled: root.store && !root.store.contactsSyncing
        onClicked: root.store.syncContacts()
      }

      PanelActionButton {
        id: addBtn
        iconText: "󰐕"
        tooltipText: "Add an address book"
        foreground: root.fg
        fontFamily: root.fontFamily
        enabled: root.store && root.store.writable
        onClicked: root.addRequested()
      }
    }
  }

  Repeater {
    model: root.books.length > 1 ? [{ id: "", name: "All contacts" }].concat(root.books) : root.books

    Rectangle {
      id: bookRow
      required property var modelData
      readonly property bool all: modelData.id === ""
      readonly property bool current: root.selectedBook === modelData.id || (root.books.length === 1 && !all)
      readonly property var status: root.store && !all ? root.store.bookStatus(modelData.id) : null
      readonly property bool failed: !!(status && status.error)
      width: root.width
      height: Style.space(28)
      radius: Style.cornerRadius
      color: current ? Style.selectedFillFor(root.fg, Color.accent)
        : bookMouse.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"

      MouseArea {
        id: bookMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.selected(bookRow.modelData.id)
      }

      Text {
        id: bookIcon
        x: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        text: bookRow.all ? "\uf2b9" : "\uf02d"
        color: bookRow.current ? Color.accent : root.faintFg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Text {
        anchors.left: bookIcon.right
        anchors.leftMargin: Style.space(10)
        anchors.right: bookCount.left
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        elide: Text.ElideRight
        textFormat: Text.PlainText
        text: bookRow.modelData.name
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Text {
        id: bookCount
        anchors.right: bookBadge.left
        anchors.rightMargin: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: !root.store ? "" : bookRow.all ? String(root.store.contacts.length) : String(root.store.bookCount(bookRow.modelData.id))
        color: root.faintFg
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        id: bookBadge
        anchors.right: bookRow.all ? parent.right : bookEdit.left
        anchors.rightMargin: bookRow.all ? Style.space(6) : 0
        anchors.verticalCenter: parent.verticalCenter
        width: text === "" ? 0 : implicitWidth
        text: bookRow.failed ? "\uf071" : !bookRow.all && bookRow.modelData.readOnly ? "󰌾" : ""
        color: bookRow.failed ? Color.urgent : root.faintFg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body

        MouseArea {
          id: badgeMouse
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.NoButton
        }

        PanelToolTip {
          visible: badgeMouse.containsMouse && parent.text !== ""
          text: root.store && !bookRow.all ? root.store.bookLabel(bookRow.modelData.id) + "\n" + root.store.bookSyncLine(bookRow.modelData.id) : ""
          fontFamily: root.fontFamily
        }
      }

      PanelActionButton {
        id: bookEdit
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: !bookRow.all
        opacity: bookMouse.containsMouse ? 1 : 0.35
        iconText: "󰏫"
        tooltipText: "Address book settings"
        foreground: root.fg
        fontFamily: root.fontFamily
        fontSize: Style.font.body
        onClicked: root.editRequested(bookRow.modelData)
      }
    }
  }

  Text {
    visible: root.books.length === 0
    width: parent.width
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    text: "No address books yet. Press + to add one from iCloud, Fastmail, Nextcloud or another CardDAV server."
    color: root.faintFg
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}
