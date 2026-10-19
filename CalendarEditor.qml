import QtQuick
import qs.Commons
import qs.Ui
import "Palette.js" as Palette

// New calendar (local / subscribed link / CalDAV account) and edit-calendar
// form, shared by the popout and the window. Emits finished() when done.
Column {
  id: root

  property var store: null
  property color fg: Color.foreground
  property string fontFamily: Style.font.family

  signal finished()

  property var editingCalendar: null
  property string colorSpec: "theme:accent"
  property string kind: "local"           // "local" | "link" | "account"
  property string provider: "icloud"
  property var discovered: []             // [{url, name, color, readOnly, picked}]
  property string discoveredAccountId: ""
  property string discoveredServer: ""
  property string formError: ""
  property bool confirmDelete: false
  property bool saving: false

  readonly property bool isNew: editingCalendar === null
  readonly property bool picking: isNew && kind === "account" && discovered.length > 0
  readonly property bool signingIn: isNew && kind === "account" && !picking
  readonly property bool remoteCal: !isNew && store && store.isRemote(editingCalendar.id)
  readonly property color dimFg: Qt.darker(fg, 1.5)
  readonly property color faintFg: Qt.darker(fg, 1.9)

  readonly property var linkHelp: [
    "Google: calendar.google.com → ⚙ Settings → pick the calendar → Integrate calendar → \"Secret address in iCal format\".",
    "Outlook: Settings → Calendar → Shared calendars → Publish a calendar → \"Can view all details\" → copy the ICS link.",
    "Proton: Calendar → Settings → Calendars → Share → \"Share with anyone\" → full view → copy link.",
    "Links are read-only, kept in your keyring, and refresh every " + (store ? store.syncMinutes : 15) + " min. Google can take hours to publish changes."
  ]
  readonly property var providerOptions: [
    { value: "icloud", label: "iCloud" },
    { value: "fastmail", label: "Fastmail" },
    { value: "nextcloud", label: "Nextcloud" },
    { value: "caldav", label: "Other CalDAV server" }
  ]
  readonly property var providerHelp: ({
    icloud: "Use your Apple ID email and an app-specific password: account.apple.com → Sign-In and Security → App-Specific Passwords. Your normal Apple ID password will not work.",
    fastmail: "Use your Fastmail address and an app password with CalDAV access: Settings → Privacy & Security → Manage app passwords.",
    nextcloud: "Server is your Nextcloud address (e.g. cloud.example.com). Create an app password under Personal settings → Security.",
    caldav: "Enter the CalDAV server or principal URL and your username/password (an app password if the service offers one)."
  })
  readonly property var providerServer: ({ icloud: "https://caldav.icloud.com/", fastmail: "https://caldav.fastmail.com/", nextcloud: "", caldav: "" })

  spacing: Style.space(8)
  Keys.onPressed: function(event) { root.handleKey(event) }

  function trim(t) { return String(t || "").replace(/^\s+|\s+$/g, "") }

  function focusFirst() {
    Qt.callLater(function() {
      if (!root.isNew) { nameField.forceActiveFocus(); nameField.selectAll() }
      else if (root.kind === "link") linkField.forceActiveFocus()
      else if (root.kind === "account") usernameField.forceActiveFocus()
      else nameField.forceActiveFocus()
    })
  }

  function setProvider(p) {
    root.provider = p
    serverField.text = root.providerServer[p] || ""
  }

  function openNew(k) {
    root.editingCalendar = null
    root.colorSpec = store ? store.suggestedColor() : "theme:accent"
    root.formError = ""
    root.confirmDelete = false
    root.saving = false
    root.kind = k || "local"
    root.discovered = []
    root.discoveredAccountId = ""
    nameField.text = ""
    hexField.text = ""
    linkField.text = ""
    usernameField.text = ""
    passwordField.text = ""
    setProvider(root.provider)
    focusFirst()
  }

  function openEdit(cal) {
    root.editingCalendar = cal
    root.colorSpec = cal.color || "theme:accent"
    root.formError = ""
    root.confirmDelete = false
    root.saving = false
    var t = store.sourceType(cal.id)
    root.kind = t === "ics" ? "link" : t === "caldav" ? "account" : "local"
    nameField.text = cal.name || ""
    hexField.text = Palette.isThemeSpec(cal.color) ? "" : String(cal.color || "")
    linkField.text = ""
    focusFirst()
  }

  function cleanup() {
    // Signed in but backed out before adding anything: drop the stored password.
    if (root.discoveredAccountId !== "" && store) store.abandonAccount(root.discoveredAccountId)
    root.discoveredAccountId = ""
    root.discovered = []
    passwordField.text = ""
    linkField.text = ""
    root.editingCalendar = null
  }

  function cancel() {
    if (root.saving) return
    cleanup()
    root.finished()
  }

  function done() {
    root.saving = false
    cleanup()
    root.finished()
  }

  function save() {
    if (!store || root.saving) return
    var name = trim(nameField.text)

    if (!root.isNew) {
      if (name === "") { root.formError = "Give the calendar a name"; return }
      store.updateCalendar(root.editingCalendar.id, { name: name, color: root.colorSpec })
      var newLink = trim(linkField.text)
      if (root.kind === "link" && newLink !== "") {
        root.saving = true
        var id = root.editingCalendar.id
        store.replaceSubscriptionUrl(id, newLink, function(res) {
          root.saving = false
          var st = res.results && res.results[id]
          if (!res.ok && !st) { root.formError = res.error || "Could not save the link"; return }
          if (st && !st.ok) { root.formError = st.error; return }
          root.done()
        })
        return
      }
      done()
      return
    }

    if (root.kind === "local") {
      if (name === "") { root.formError = "Give the calendar a name"; return }
      store.addCalendar(name, root.colorSpec)
      done()
    } else if (root.kind === "link") {
      var url = trim(linkField.text)
      if (!/^(https?|webcal):\/\//i.test(url)) { root.formError = "Paste the full link (starting with https:// or webcal://)"; return }
      if (name === "") name = store.linkLabel(url)
      root.saving = true
      root.formError = ""
      // A link that fails its first fetch is still kept: the calendar row
      // shows the error and the link can be replaced from its edit form.
      store.addSubscription(name, url, root.colorSpec, function(res) {
        root.saving = false
        if (!res.ok) { root.formError = res.error; return }
        root.done()
      })
    } else if (root.discovered.length === 0) connect()
    else addPicked()
  }

  function connect() {
    var user = trim(usernameField.text)
    if (user === "" || passwordField.text === "") { root.formError = "Enter the username and app password"; return }
    var server = trim(serverField.text)
    if ((root.provider === "nextcloud" || root.provider === "caldav") && server === "") { root.formError = "Enter the server address"; return }
    if (root.provider === "nextcloud" && server.indexOf("remote.php") === -1) server = server.replace(/\/+$/, "") + "/remote.php/dav/"
    root.saving = true
    root.formError = ""
    store.discoverAccount({ provider: root.provider, server: server, username: user, password: passwordField.text }, function(res) {
      root.saving = false
      passwordField.text = ""
      if (!res.ok) { root.formError = res.error; return }
      root.discoveredAccountId = res.accountId
      root.discoveredServer = server
      root.discovered = res.calendars.map(function(c) {
        return { url: c.url, name: c.name, color: c.color, readOnly: c.readOnly, picked: true }
      })
      // The password field just disappeared; keep Enter/Esc working.
      Qt.callLater(function() { root.forceActiveFocus() })
    })
  }

  function togglePick(index) {
    var next = root.discovered.slice()
    var item = {}
    for (var k in next[index]) item[k] = next[index][k]
    item.picked = !item.picked
    next[index] = item
    root.discovered = next
  }

  function addPicked() {
    var picks = root.discovered.filter(function(c) { return c.picked })
    if (picks.length === 0) { root.formError = "Pick at least one calendar"; return }
    store.addAccountCalendars(root.discoveredAccountId, root.provider, root.discoveredServer, trim(usernameField.text), picks)
    root.discoveredAccountId = ""   // owned by the account now; do not abandon
    done()
  }

  function remove() {
    if (!store || !root.editingCalendar) return
    if (!root.confirmDelete) { root.confirmDelete = true; return }
    store.removeCalendar(root.editingCalendar.id)
    done()
  }

  function handleKey(event) {
    if (event.key === Qt.Key_Escape) { cancel(); event.accepted = true }
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { event.accepted = true; save() }
  }

  PanelSectionHeader {
    text: !root.isNew ? "EDIT CALENDAR"
      : root.kind === "link" ? "SUBSCRIBE TO A LINK"
      : root.kind === "account" ? "CONNECT AN ACCOUNT" : "NEW CALENDAR"
    foreground: root.fg
    fontFamily: root.fontFamily
  }

  ButtonGroup {
    visible: root.isNew && !root.picking
    options: [
      { value: "local", label: "Local" },
      { value: "link", label: "Link" },
      { value: "account", label: "Account" }
    ]
    value: root.kind
    foreground: root.fg
    fontFamily: root.fontFamily
    onChanged: function(v) { root.kind = v; root.formError = ""; root.focusFirst() }
  }

  // ---- name + color (not during account sign-in)
  Row {
    visible: !(root.isNew && root.kind === "account")
    width: parent.width
    spacing: Style.space(10)

    Swatch {
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(18)
      swatch: root.store ? root.store.colorFor(root.colorSpec) : Color.accent
    }

    TextField {
      id: nameField
      width: parent.width - Style.space(28)
      placeholderText: root.kind === "link" && root.isNew ? "Name (optional)" : "Calendar name"
      foreground: root.fg
      font.family: root.fontFamily
    }
  }

  Text {
    visible: root.remoteCal
    width: parent.width
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    text: root.remoteCal ? root.store.sourceLabel(root.editingCalendar.id) + "\n" + root.store.syncLine(root.editingCalendar.id) : ""
    color: root.remoteCal && root.store.syncStatus(root.editingCalendar.id) && root.store.syncStatus(root.editingCalendar.id).error
      ? Color.urgent : root.dimFg
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  // ---- link
  TextField {
    id: linkField
    visible: root.kind === "link"
    width: parent.width
    password: true
    placeholderText: root.isNew ? "Paste the private iCal / ICS link" : "Paste a new link to replace it (optional)"
    foreground: root.fg
    font.family: root.fontFamily
  }

  Column {
    visible: root.kind === "link" && root.isNew
    width: parent.width
    spacing: Style.space(4)
    Repeater {
      model: root.linkHelp
      Text {
        required property var modelData
        width: parent.width
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
        text: modelData
        color: root.faintFg
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  // ---- account sign-in
  Dropdown {
    visible: root.signingIn
    width: parent.width
    showLabel: false
    value: root.provider
    options: root.providerOptions
    foreground: root.fg
    fontFamily: root.fontFamily
    onChanged: function(v) { root.setProvider(v) }
  }

  TextField {
    id: serverField
    visible: root.signingIn && (root.provider === "nextcloud" || root.provider === "caldav")
    width: parent.width
    placeholderText: root.provider === "nextcloud" ? "cloud.example.com" : "https://dav.example.com/"
    foreground: root.fg
    font.family: root.fontFamily
  }

  TextField {
    id: usernameField
    visible: root.signingIn
    width: parent.width
    placeholderText: root.provider === "icloud" ? "Apple ID email" : "Username or email"
    foreground: root.fg
    font.family: root.fontFamily
  }

  TextField {
    id: passwordField
    visible: root.signingIn
    width: parent.width
    password: true
    placeholderText: "App-specific password"
    foreground: root.fg
    font.family: root.fontFamily
  }

  Text {
    visible: root.signingIn
    width: parent.width
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    text: (root.providerHelp[root.provider] || "") + " The password is kept in your keyring."
    color: root.faintFg
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  // ---- account: pick calendars
  Caption { visible: root.picking; foreground: root.fg; fontFamily: root.fontFamily; text: "CHOOSE CALENDARS" }

  Repeater {
    model: root.picking ? root.discovered : []

    Rectangle {
      id: pickRow
      required property var modelData
      required property int index
      width: root.width
      height: Style.space(28)
      radius: Style.cornerRadius
      color: pickMouse.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"

      Text {
        id: pickCheck
        x: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        text: pickRow.modelData.picked ? "󰄲" : "󰄱"
        color: pickRow.modelData.picked ? Color.accent : root.faintFg
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
      }

      Text {
        anchors.left: pickCheck.right
        anchors.leftMargin: Style.space(10)
        anchors.right: parent.right
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        elide: Text.ElideRight
        textFormat: Text.PlainText
        text: pickRow.modelData.name + (pickRow.modelData.readOnly ? "  (read-only)" : "")
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      MouseArea {
        id: pickMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.togglePick(pickRow.index)
      }
    }
  }

  Text {
    visible: root.picking
    width: parent.width
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    text: "Each gets its own theme color; change it later with the pencil."
    color: root.faintFg
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  // ---- color picker
  Caption { visible: !(root.isNew && root.kind === "account"); foreground: root.fg; fontFamily: root.fontFamily; text: "THEME COLORS" }

  Flow {
    visible: !(root.isNew && root.kind === "account")
    width: parent.width
    spacing: Style.space(8)

    Repeater {
      model: root.store ? root.store.suggestions : []

      Item {
        id: swItem
        required property var modelData
        width: Style.space(26)
        height: width

        Swatch {
          anchors.centerIn: parent
          width: Style.space(18)
          swatch: swItem.modelData.hex
          ring: root.colorSpec === swItem.modelData.spec
          ringColor: root.fg
        }

        MouseArea {
          id: swMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: { root.colorSpec = swItem.modelData.spec; hexField.text = "" }
        }

        PanelToolTip {
          visible: swMouse.containsMouse
          text: swItem.modelData.label
          fontFamily: root.fontFamily
        }
      }
    }
  }

  Caption { visible: !(root.isNew && root.kind === "account"); foreground: root.fg; fontFamily: root.fontFamily; text: "CUSTOM" }

  TextField {
    id: hexField
    visible: !(root.isNew && root.kind === "account")
    width: parent.width
    placeholderText: "#rrggbb (fixed, ignores theme)"
    foreground: root.fg
    font.family: root.fontFamily
    onTextChanged: {
      var hex = Palette.normalizeHex(text)
      if (hex !== "") root.colorSpec = hex
    }
  }

  Text {
    visible: !(root.isNew && root.kind === "account")
    width: parent.width
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    text: Palette.isThemeSpec(root.colorSpec)
      ? Palette.label(root.colorSpec) + " — follows the system theme"
      : "Custom " + root.colorSpec + " — stays fixed across themes"
    color: root.dimFg
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
      text: root.saving ? (root.kind === "account" ? "Signing in…" : "Checking…")
        : !root.isNew ? "Save"
        : root.kind === "link" ? "Subscribe"
        : root.kind === "account" ? (root.picking
            ? "Add " + root.discovered.filter(function(c) { return c.picked }).length + " calendars"
            : "Connect")
        : "Save"
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
    Button {
      visible: root.remoteCal
      text: "Sync now"
      enabled: root.store && !root.store.syncing
      bordered: true
      foreground: root.fg
      fontFamily: root.fontFamily
      onClicked: root.store.syncCalendar(root.editingCalendar.id, null)
    }
  }

  Button {
    visible: !root.isNew
    text: root.confirmDelete
      ? (root.remoteCal ? "Really remove? (nothing is deleted on the server)"
         : "Really delete" + (root.editingCalendar && root.store
            ? " with " + root.store.eventCount(root.editingCalendar.id) + " events?" : "?"))
      : (root.remoteCal ? "Remove calendar" : "Delete calendar")
    bordered: true
    foreground: root.confirmDelete ? Color.urgent : root.fg
    fontFamily: root.fontFamily
    onClicked: root.remove()
  }
}
