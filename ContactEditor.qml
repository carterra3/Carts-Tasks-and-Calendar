import QtQuick
import qs.Commons
import qs.Ui
import "Contacts.js" as Contacts

// New / edit contact form for the window's drawer. Saves straight to the
// CardDAV server through the store; emits finished(key) with the saved
// contact's key ("" when cancelled or deleted).
Column {
  id: root

  property var store: null
  property color fg: Color.foreground
  property string fontFamily: Style.font.family

  signal finished(string key)

  property var editing: null            // the record being edited, or null
  property var form: Contacts.formFor(null)
  property string formError: ""
  property bool saving: false
  property bool confirmDelete: false

  readonly property bool isNew: editing === null
  readonly property color faintFg: Qt.darker(fg, 1.9)
  readonly property var bookOptions: store ? store.writableBooks.map(function(b) { return { value: b.id, label: b.name } }) : []

  spacing: Style.space(8)
  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Escape) { root.cancel(); event.accepted = true }
    else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !(event.modifiers & Qt.ShiftModifier)) { event.accepted = true; root.save() }
  }

  function typeOptions(types) { return types.map(function(t) { return { value: t, label: Contacts.typeLabel(t) } }) }

  function load(contact, bookId) {
    root.editing = contact
    var f = Contacts.formFor(contact)
    if (!contact) {
      f.bookId = bookId && store.bookWritable(bookId) ? bookId : (store.writableBooks.length ? store.writableBooks[0].id : "")
      f.phones = [{ type: "cell", value: "" }]
      f.emails = [{ type: "home", value: "" }]
    }
    root.form = f
    root.formError = ""
    root.saving = false
    root.confirmDelete = false
    Qt.callLater(function() { givenField.forceActiveFocus() })
  }

  function openNew(bookId) { load(null, bookId) }
  function openEdit(contact) { load(contact, "") }

  function setField(name, value) { root.form[name] = value }
  // Row edits mutate in place so the Repeater (and the focused field) stay put.
  function setRow(list, index, key, value) { root.form[list][index][key] = value }
  function addRow(list, row) {
    var f = root.form
    f[list] = f[list].concat([row])
    root.form = Object.assign({}, f)
  }
  function removeRow(list, index) {
    var f = root.form
    f[list] = f[list].filter(function(_, i) { return i !== index })
    root.form = Object.assign({}, f)
  }

  function cancel() {
    if (root.saving) return
    root.editing = null
    root.finished("")
  }

  function save() {
    if (!store || root.saving) return
    var r = Contacts.buildContact(root.form, root.editing)
    if (r.error) { root.formError = r.error; return }
    root.saving = true
    root.formError = ""
    var moving = !root.isNew && root.editing.bookId !== r.contact.bookId
    var done = function(err, saved) {
      root.saving = false
      if (err) { root.formError = err; return }
      root.editing = null
      root.finished(saved ? Contacts.keyOf(saved) : "")
    }
    // moveContact writes the given record into the new book, then deletes
    // it (by href, from its current book) in the old one.
    if (moving) store.moveContact(Object.assign({}, r.contact, { bookId: root.editing.bookId }), r.contact.bookId, done)
    else store.saveContact(r.contact, done)
  }

  function remove() {
    if (!store || !root.editing || root.saving) return
    if (!root.confirmDelete) { root.confirmDelete = true; return }
    root.saving = true
    store.deleteContact(root.editing, function(err) {
      root.saving = false
      root.confirmDelete = false
      if (err) { root.formError = err; return }
      root.editing = null
      root.finished("")
    })
  }

  PanelSectionHeader {
    text: root.isNew ? "NEW CONTACT" : "EDIT CONTACT"
    foreground: root.fg
    fontFamily: root.fontFamily
  }

  // ---- name
  Row {
    width: parent.width
    spacing: Style.space(8)
    TextField {
      id: givenField
      width: (parent.width - Style.space(8)) / 2
      placeholderText: "First name"
      text: root.form.given !== "" || root.form.fnOnly === "" ? root.form.given : root.form.fnOnly
      foreground: root.fg
      font.family: root.fontFamily
      onTextEdited: { root.setField("given", text); root.setField("fnOnly", "") }
    }
    TextField {
      width: (parent.width - Style.space(8)) / 2
      placeholderText: "Last name"
      text: root.form.family
      foreground: root.fg
      font.family: root.fontFamily
      onTextEdited: { root.setField("family", text); if (root.form.fnOnly) { root.setField("given", givenField.text); root.setField("fnOnly", "") } }
    }
  }
  TextField {
    width: parent.width
    placeholderText: "Company"
    text: root.form.org
    foreground: root.fg
    font.family: root.fontFamily
    onTextEdited: root.setField("org", text)
  }
  TextField {
    width: parent.width
    placeholderText: "Job title"
    text: root.form.title
    foreground: root.fg
    font.family: root.fontFamily
    onTextEdited: root.setField("title", text)
  }

  // ---- phones / emails / web: typed single-line rows
  Repeater {
    model: [
      { list: "phones", caption: "PHONE", add: "Add phone", types: Contacts.PHONE_TYPES, fresh: "cell", hint: "Phone number" },
      { list: "emails", caption: "EMAIL", add: "Add email", types: Contacts.EMAIL_TYPES, fresh: "home", hint: "Email address" },
      { list: "urls", caption: "WEBSITE", add: "Add website", types: [], fresh: "", hint: "example.com" }
    ]

    Column {
      id: block
      required property var modelData
      width: root.width
      spacing: Style.space(6)

      Caption { foreground: root.fg; fontFamily: root.fontFamily; text: block.modelData.caption }

      Repeater {
        model: root.form[block.modelData.list]

        Row {
          id: lineRow
          required property var modelData
          required property int index
          width: block.width
          spacing: Style.space(6)

          Dropdown {
            id: typeBox
            visible: block.modelData.types.length > 0
            width: visible ? Style.space(96) : 0
            showLabel: false
            value: lineRow.modelData.type || block.modelData.fresh
            options: root.typeOptions(block.modelData.types)
            foreground: root.fg
            fontFamily: root.fontFamily
            onChanged: function(v) { root.setRow(block.modelData.list, lineRow.index, "type", v); value = v }
          }
          TextField {
            width: block.width - typeBox.width - removeBtn.width - Style.space(6) * (typeBox.visible ? 2 : 1)
            placeholderText: block.modelData.hint
            text: lineRow.modelData.value
            foreground: root.fg
            font.family: root.fontFamily
            onTextEdited: root.setRow(block.modelData.list, lineRow.index, "value", text)
          }
          PanelActionButton {
            id: removeBtn
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰅖"
            tooltipText: "Remove"
            foreground: root.faintFg
            fontFamily: root.fontFamily
            fontSize: Style.font.body
            onClicked: root.removeRow(block.modelData.list, lineRow.index)
          }
        }
      }

      Button {
        text: block.modelData.add
        iconText: "󰐕"
        foreground: root.fg
        fontFamily: root.fontFamily
        onClicked: root.addRow(block.modelData.list, block.modelData.types.length
          ? { type: block.modelData.fresh, value: "" } : { value: "" })
      }
    }
  }

  // ---- addresses
  Caption { foreground: root.fg; fontFamily: root.fontFamily; text: "ADDRESS" }

  Repeater {
    model: root.form.addresses

    Column {
      id: adr
      required property var modelData
      required property int index
      width: root.width
      spacing: Style.space(6)

      Row {
        width: parent.width
        spacing: Style.space(6)
        Dropdown {
          width: Style.space(96)
          showLabel: false
          value: adr.modelData.type || "home"
          options: root.typeOptions(Contacts.ADDRESS_TYPES)
          foreground: root.fg
          fontFamily: root.fontFamily
          onChanged: function(v) { root.setRow("addresses", adr.index, "type", v); value = v }
        }
        Item { width: parent.width - Style.space(96) - adrRemove.width - Style.space(12); height: 1 }
        PanelActionButton {
          id: adrRemove
          anchors.verticalCenter: parent.verticalCenter
          iconText: "󰅖"
          tooltipText: "Remove address"
          foreground: root.faintFg
          fontFamily: root.fontFamily
          fontSize: Style.font.body
          onClicked: root.removeRow("addresses", adr.index)
        }
      }
      TextBox {
        width: parent.width
        placeholderText: "Street"
        text: adr.modelData.street
        foreground: root.fg
        font.family: root.fontFamily
        onTextChanged: if (activeFocus) root.setRow("addresses", adr.index, "street", text)
      }
      Row {
        width: parent.width
        spacing: Style.space(6)
        TextField {
          width: (parent.width - Style.space(12)) * 0.5
          placeholderText: "City"
          text: adr.modelData.city
          foreground: root.fg
          font.family: root.fontFamily
          onTextEdited: root.setRow("addresses", adr.index, "city", text)
        }
        TextField {
          width: (parent.width - Style.space(12)) * 0.25
          placeholderText: "State"
          text: adr.modelData.region
          foreground: root.fg
          font.family: root.fontFamily
          onTextEdited: root.setRow("addresses", adr.index, "region", text)
        }
        TextField {
          width: (parent.width - Style.space(12)) * 0.25
          placeholderText: "Postcode"
          text: adr.modelData.code
          foreground: root.fg
          font.family: root.fontFamily
          onTextEdited: root.setRow("addresses", adr.index, "code", text)
        }
      }
      TextField {
        width: parent.width
        placeholderText: "Country"
        text: adr.modelData.country
        foreground: root.fg
        font.family: root.fontFamily
        onTextEdited: root.setRow("addresses", adr.index, "country", text)
      }
    }
  }

  Button {
    text: "Add address"
    iconText: "󰐕"
    foreground: root.fg
    fontFamily: root.fontFamily
    onClicked: root.addRow("addresses", { type: "home", street: "", city: "", region: "", code: "", country: "" })
  }

  // ---- birthday, notes, address book
  Caption { foreground: root.fg; fontFamily: root.fontFamily; text: "BIRTHDAY" }
  TextField {
    width: parent.width
    placeholderText: "yyyy-mm-dd, or mm-dd without a year"
    text: root.form.birthday
    foreground: root.fg
    font.family: root.fontFamily
    onTextEdited: root.setField("birthday", text)
  }

  Caption { foreground: root.fg; fontFamily: root.fontFamily; text: "NOTES" }
  TextBox {
    width: parent.width
    height: Math.max(Style.space(70), implicitHeight)
    placeholderText: "Notes"
    text: root.form.notes
    foreground: root.fg
    font.family: root.fontFamily
    onTextChanged: if (activeFocus) root.setField("notes", text)
  }

  Caption { visible: root.bookOptions.length > 1; foreground: root.fg; fontFamily: root.fontFamily; text: "ADDRESS BOOK" }
  Dropdown {
    visible: root.bookOptions.length > 1
    width: parent.width
    showLabel: false
    value: root.form.bookId
    options: root.bookOptions
    foreground: root.fg
    fontFamily: root.fontFamily
    onChanged: function(v) { root.setField("bookId", v); value = v }
  }
  Text {
    visible: !root.isNew && root.editing && root.form.bookId !== root.editing.bookId
    width: parent.width
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    text: "Saving moves the contact: it is created in the new address book, then removed from the old one."
    color: root.faintFg
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    visible: root.formError !== ""
    width: parent.width
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    text: root.formError
    color: Color.urgent
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  Row {
    spacing: Style.space(8)
    Button {
      text: root.saving ? "Saving…" : "Save"
      enabled: !root.saving
      bordered: true
      selected: true
      foreground: root.fg
      fontFamily: root.fontFamily
      onClicked: root.save()
    }
    Button {
      text: "Cancel"
      enabled: !root.saving
      bordered: true
      foreground: root.fg
      fontFamily: root.fontFamily
      onClicked: root.cancel()
    }
  }

  Button {
    visible: !root.isNew
    text: root.confirmDelete ? "Really delete? This removes it from the server" : "Delete contact"
    enabled: !root.saving
    bordered: true
    foreground: root.confirmDelete ? Color.urgent : root.fg
    fontFamily: root.fontFamily
    onClicked: root.remove()
  }
}
