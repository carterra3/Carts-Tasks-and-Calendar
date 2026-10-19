import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Contacts.js" as Contacts

// The Contacts mode's main area: a searchable, sectioned list on the left
// and the selected contact's card on the right. Editing happens in the
// window's drawer (ContactEditor); this view only shows and selects.
Item {
  id: root

  property var store: null
  property string bookId: ""            // "" = every address book
  property string query: ""
  property string selectedKey: ""       // Contacts.keyOf() of the selected contact
  property color fg: Color.foreground
  property string fontFamily: Style.font.family

  signal editRequested(var contact)
  signal newRequested()
  signal addBookRequested()
  signal selectRequested(string key)
  signal notice(string text)

  readonly property color dimFg: Qt.darker(fg, 1.5)
  readonly property color faintFg: Qt.darker(fg, 1.9)
  readonly property bool hasBooks: store && store.addressBooks.length > 0
  readonly property var list: store ? Contacts.filtered(store.contacts, bookId, query) : []
  readonly property int currentIndex: Contacts.indexOfKey(list, selectedKey)
  readonly property var current: currentIndex >= 0 ? list[currentIndex] : null
  readonly property var currentBook: current && store ? store.bookById(current.bookId) : null

  // Keep a selection while there is anything to select.
  onListChanged: if (currentIndex < 0 && list.length) Qt.callLater(function() { if (root.currentIndex < 0 && root.list.length) root.selectRequested(Contacts.keyOf(root.list[0])) })

  function move(delta) {
    if (!list.length) return
    var i = currentIndex < 0 ? 0 : Math.max(0, Math.min(list.length - 1, currentIndex + delta))
    selectRequested(Contacts.keyOf(list[i]))
    listView.positionViewAtIndex(i, ListView.Contain)
  }

  function open(url) { Qt.openUrlExternally(url) }
  function copy(text) {
    Quickshell.execDetached(["wl-copy", "--", String(text)])
    root.notice("Copied " + String(text).split("\n")[0])
  }

  component Avatar: Rectangle {
    id: av
    property var contact: null
    property real size: Style.space(28)
    width: size
    height: size
    radius: Style.cornerRadius > 0 ? size / 2 : Style.space(3)
    color: Util.alpha(Color.accent, 0.22)
    clip: true

    Text {
      anchors.centerIn: parent
      visible: photo.status !== Image.Ready
      textFormat: Text.PlainText
      text: Contacts.initials(av.contact)
      color: Color.accent
      font.family: root.fontFamily
      font.pixelSize: av.size * 0.4
      font.bold: true
    }

    Image {
      id: photo
      anchors.fill: parent
      source: av.contact && av.contact.photo ? av.contact.photo : ""
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      sourceSize.width: av.size * 2
      sourceSize.height: av.size * 2
      visible: status === Image.Ready
    }
  }

  // ------------------------------------------------------------ empty states
  Column {
    visible: !root.hasBooks
    anchors.centerIn: parent
    width: Math.min(parent.width - Style.space(40), Style.space(420))
    spacing: Style.space(12)

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: "󰀉"
      color: root.faintFg
      font.family: root.fontFamily
      font.pixelSize: Style.font.display * 2
    }
    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.Wrap
      textFormat: Text.PlainText
      text: "Connect an address book to see your contacts here. They stay on your server (iCloud, Fastmail, Nextcloud or any CardDAV service) and sync both ways."
      color: root.dimFg
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
    Button {
      anchors.horizontalCenter: parent.horizontalCenter
      text: "Add an address book"
      iconText: "󰐕"
      bordered: true
      selected: true
      foreground: root.fg
      fontFamily: root.fontFamily
      onClicked: root.addBookRequested()
    }
  }

  // ------------------------------------------------------------------- list
  Item {
    id: listPane
    visible: root.hasBooks
    width: Math.max(Style.space(220), Math.min(Style.space(320), parent.width * 0.4))
    height: parent.height

    Text {
      visible: root.list.length === 0
      anchors.horizontalCenter: parent.horizontalCenter
      y: Style.space(30)
      width: parent.width - Style.space(20)
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.Wrap
      textFormat: Text.PlainText
      text: root.query !== "" ? "No contacts match \u201c" + root.query + "\u201d"
        : root.store && root.store.contactsSyncing ? "Loading contacts…" : "No contacts in this address book yet"
      color: root.faintFg
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    ListView {
      id: listView
      anchors.fill: parent
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      model: root.list
      reuseItems: true

      // ListView sections need a model role, which a JS array lacks, so the
      // first row of each letter draws the letter itself.
      delegate: Item {
        id: row
        required property var modelData
        required property int index
        readonly property string letter: Contacts.sectionOf(modelData)
        readonly property bool first: index === 0 || Contacts.sectionOf(root.list[index - 1]) !== letter
        readonly property bool isCurrent: index === root.currentIndex
        width: listView.width - Style.space(6)
        height: rowBox.height + (first ? letterText.height + Style.space(6) : 0)

        Text {
          id: letterText
          visible: row.first
          x: Style.space(8)
          y: row.index === 0 ? 0 : Style.space(4)
          textFormat: Text.PlainText
          text: row.letter
          color: Color.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }

        Rectangle {
          id: rowBox
          anchors.bottom: parent.bottom
          width: parent.width
          height: Style.space(44)
          radius: Style.cornerRadius
          color: row.isCurrent ? Style.selectedFillFor(root.fg, Color.accent)
            : rowMouse.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"

          Avatar {
            id: rowAvatar
            x: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            contact: row.modelData
            size: Style.space(30)
          }

          Column {
            anchors.left: rowAvatar.right
            anchors.leftMargin: Style.space(10)
            anchors.right: parent.right
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(1)

            Text {
              width: parent.width
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: Contacts.displayName(row.modelData) || "Unnamed"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: row.isCurrent
            }
            Text {
              readonly property string sub: row.modelData.org && row.modelData.org !== Contacts.displayName(row.modelData) ? row.modelData.org
                : row.modelData.emails && row.modelData.emails.length ? row.modelData.emails[0].value
                : row.modelData.phones && row.modelData.phones.length ? row.modelData.phones[0].value : ""
              visible: sub !== ""
              width: parent.width
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: sub
              color: root.faintFg
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          MouseArea {
            id: rowMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.selectRequested(Contacts.keyOf(row.modelData))
            onDoubleClicked: if (root.store && root.store.bookWritable(row.modelData.bookId)) root.editRequested(row.modelData)
          }
        }
      }
    }
  }

  Rectangle {
    visible: root.hasBooks
    x: listPane.width + Style.space(12)
    width: Style.spacing.hairline
    height: parent.height
    color: root.fg
    opacity: 0.1
  }

  // ----------------------------------------------------------------- detail
  Flickable {
    id: detail
    visible: root.hasBooks && root.current !== null
    x: listPane.width + Style.space(28)
    width: parent.width - x
    height: parent.height
    contentWidth: width
    contentHeight: card.implicitHeight + Style.space(20)
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: card
      width: Math.min(detail.width - Style.space(8), Style.space(640))
      spacing: Style.space(16)

      Row {
        width: parent.width
        spacing: Style.space(18)

        Avatar {
          contact: root.current
          size: Style.space(72)
        }

        Column {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - Style.space(72 + 2 * 18) - (editButton.visible ? editButton.width : 0)
          spacing: Style.space(4)

          Text {
            width: parent.width
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
            text: Contacts.displayName(root.current) || "Unnamed"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            font.bold: true
          }
          Text {
            readonly property string line: root.current ? [root.current.title, root.current.org].filter(function(x) { return x && x !== Contacts.displayName(root.current) }).join(" · ") : ""
            visible: line !== ""
            width: parent.width
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
            text: line
            color: root.dimFg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
          Text {
            width: parent.width
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: root.currentBook ? "\uf02d  " + root.currentBook.name + (root.currentBook.readOnly ? "  ·  read-only" : "") : ""
            color: root.faintFg
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Button {
          id: editButton
          anchors.verticalCenter: parent.verticalCenter
          visible: root.current && root.store && root.store.bookWritable(root.current.bookId)
          text: "Edit"
          tooltipText: "Edit  (e)"
          iconText: "󰏫"
          bordered: true
          foreground: root.fg
          fontFamily: root.fontFamily
          onClicked: root.editRequested(root.current)
        }
      }

      // One labelled block per kind of detail. Each row: type label on the
      // left, the value on the right; click opens it, right-click copies.
      Repeater {
        model: {
          var c = root.current
          if (!c) return []
          var out = []
          ;(c.phones || []).forEach(function(p) { out.push({ label: Contacts.typeLabel(p.type), value: p.value, url: Contacts.telUrl(p.value), icon: "󰏲" }) })
          ;(c.emails || []).forEach(function(e) { out.push({ label: Contacts.typeLabel(e.type), value: e.value, url: Contacts.mailUrl(e.value), icon: "󰇮" }) })
          ;(c.addresses || []).forEach(function(a) { out.push({ label: Contacts.typeLabel(a.type), value: Contacts.addressLines(a).join("\n"), url: Contacts.mapUrl(a), icon: "󰍎" }) })
          ;(c.urls || []).forEach(function(u) { out.push({ label: "web", value: u, url: Contacts.webUrl(u), icon: "󰖟" }) })
          var bd = Contacts.birthdayParts(c.birthday)
          if (bd) {
            var d = new Date(bd.year || 2000, bd.month - 1, bd.day)
            var text = Qt.formatDate(d, bd.year ? "MMMM d, yyyy" : "MMMM d")
            if (bd.year) {
              var now = new Date()
              var age = now.getFullYear() - bd.year - ((now.getMonth() + 1 < bd.month || (now.getMonth() + 1 === bd.month && now.getDate() < bd.day)) ? 1 : 0)
              if (age >= 0 && age < 130) text += "  (" + age + ")"
            }
            out.push({ label: "birthday", value: text, url: "", icon: "󰃭" })
          }
          return out
        }

        Item {
          id: field
          required property var modelData
          width: card.width
          height: Math.max(Style.space(30), valueText.implicitHeight + Style.space(10))

          Rectangle {
            anchors.fill: parent
            radius: Style.cornerRadius
            color: fieldMouse.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"
          }
          Text {
            id: fieldIcon
            x: Style.space(6)
            y: Style.space(5)
            text: field.modelData.icon
            color: root.faintFg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
          Text {
            id: fieldLabel
            anchors.left: fieldIcon.right
            anchors.leftMargin: Style.space(10)
            y: Style.space(5)
            width: Style.space(70)
            textFormat: Text.PlainText
            text: field.modelData.label
            color: root.dimFg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          Text {
            id: valueText
            anchors.left: fieldLabel.right
            anchors.leftMargin: Style.space(8)
            anchors.right: parent.right
            anchors.rightMargin: Style.space(6)
            y: Style.space(5)
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
            text: field.modelData.value
            color: field.modelData.url ? Color.accent : root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
          MouseArea {
            id: fieldMouse
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            cursorShape: field.modelData.url ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: function(mouse) {
              if (mouse.button === Qt.RightButton || !field.modelData.url) root.copy(field.modelData.value)
              else root.open(field.modelData.url)
            }
          }
          PanelToolTip {
            visible: fieldMouse.containsMouse
            text: field.modelData.url ? "Click to open · right-click to copy" : "Click to copy"
            fontFamily: root.fontFamily
          }
        }
      }

      Column {
        visible: root.current && root.current.notes !== ""
        width: card.width
        spacing: Style.space(6)
        Caption { foreground: root.fg; fontFamily: root.fontFamily; text: "NOTES" }
        Text {
          width: parent.width
          wrapMode: Text.Wrap
          textFormat: Text.PlainText
          text: root.current ? root.current.notes : ""
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
      }
    }
  }
}
