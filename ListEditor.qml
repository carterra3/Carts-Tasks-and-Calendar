import QtQuick
import qs.Commons
import qs.Ui

// Add a list (on this computer, or task lists from a CalDAV account: one
// already connected for calendars, address books or tasks, or a new
// sign-in), and the settings of one list. finished() when done.
Column {
  id: root

  property var store: null
  property color fg: Color.foreground
  property string fontFamily: Style.font.family

  signal finished()
  signal added(string listId)

  property var editing: null
  property string kind: "account"           // "local" | "account" (new lists)
  property string source: "new"             // "acc:<id>" | "cal:<id>" | "new"
  property string provider: "caldav"
  property string colorSpec: ""
  property var discovered: []               // [{url, name, color, readOnly, mixed, picked, already}]
  property string discoveredAccountId: ""
  property var discoveredAccount: null
  property bool discoveredNew: false
  property string formError: ""
  property bool saving: false
  property bool confirmDelete: false

  readonly property bool isNew: editing === null
  readonly property bool picking: isNew && kind === "account" && discoveredAccountId !== ""
  readonly property bool signingIn: isNew && kind === "account" && !picking && source === "new"
  readonly property color dimFg: Qt.darker(fg, 1.5)
  readonly property color faintFg: Qt.darker(fg, 1.9)

  function loginKey(a) { return (a.provider || "caldav") + "|" + store.hostOf(a.server) + "|" + a.username }

  // Connected accounts (shared with calendars and address books).
  readonly property var accountOptions: {
    if (!store) return []
    var out = [], seen = {}
    store.accounts.forEach(function(a) {
      var k = root.loginKey(a)
      if (seen[k]) return
      seen[k] = true
      out.push({ value: "acc:" + a.id, label: store.accountLabel(a) })
    })
    out.push({ value: "new", label: "Sign in to another account…" })
    return out
  }
  readonly property var providerOptions: [
    { value: "icloud", label: "iCloud" }, { value: "fastmail", label: "Fastmail" },
    { value: "nextcloud", label: "Nextcloud" }, { value: "caldav", label: "Other CalDAV server" }
  ]
  readonly property var providerHelp: ({
    icloud: "Apple ID email and an app-specific password (account.apple.com → Sign-In and Security). iCloud only shows Reminders lists that were not upgraded to the new Reminders format.",
    fastmail: "Your Fastmail address and an app password with CalDAV access (Settings → Privacy & Security).",
    nextcloud: "Your Nextcloud address (e.g. cloud.example.com) and an app password (Personal settings → Security).",
    caldav: "The CalDAV server or principal URL and your username/password."
  })

  spacing: Style.space(8)
  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Escape) { root.cancel(); event.accepted = true }
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { event.accepted = true; root.save() }
  }

  function trim(t) { return String(t || "").replace(/^\s+|\s+$/g, "") }

  function reset() {
    root.formError = ""
    root.saving = false
    root.confirmDelete = false
    root.discovered = []
    root.discoveredAccountId = ""
    root.discoveredAccount = null
    root.discoveredNew = false
    passwordField.text = ""
    newListField.text = ""
  }

  function openNew(kind) {
    reset()
    root.editing = null
    root.kind = kind || (store.accounts.length ? "account" : "local")
    root.source = root.accountOptions.length ? root.accountOptions[0].value : "new"
    root.colorSpec = store.suggestedColor()
    nameField.text = ""
    usernameField.text = ""
    serverField.text = ""
    Qt.callLater(function() { if (root.kind === "local") nameField.forceActiveFocus(); else root.forceActiveFocus() })
  }

  function openEdit(list) {
    reset()
    root.editing = list
    root.colorSpec = list.color
    nameField.text = list.name || ""
    Qt.callLater(function() { nameField.forceActiveFocus(); nameField.selectAll() })
  }

  function cleanup() {
    if (root.discoveredNew && root.discoveredAccountId !== "" && store) store.abandonAccount(root.discoveredAccountId)
    reset()
    root.editing = null
  }

  function cancel() {
    if (root.saving) return
    cleanup()
    root.finished()
  }

  function save() {
    if (!store || root.saving) return
    if (!root.isNew) {
      var name = trim(nameField.text)
      if (!name) { root.formError = "Give the list a name"; return }
      store.updateList(root.editing.id, { name: name, color: root.colorSpec })
      cleanup()
      root.finished()
      return
    }
    if (root.kind === "local") {
      var n = trim(nameField.text)
      if (!n) { root.formError = "Give the list a name"; return }
      var id = store.addLocalList(n, root.colorSpec)
      cleanup()
      root.added(id)
      root.finished()
      return
    }
    if (root.picking) { addPicked(); return }
    connect()
  }

  function connect() {
    var form
    if (root.source === "new") {
      var user = trim(usernameField.text)
      if (!user || passwordField.text === "") { root.formError = "Enter the username and app password"; return }
      var server = trim(serverField.text)
      if ((root.provider === "nextcloud" || root.provider === "caldav") && !server) { root.formError = "Enter the server address"; return }
      if (root.provider === "nextcloud" && server.indexOf("remote.php") === -1) server = server.replace(/\/+$/, "") + "/remote.php/dav/"
      form = { provider: root.provider, server: server, username: user, password: passwordField.text }
    } else form = { accountId: root.source.substr(4) }
    root.saving = true
    root.formError = ""
    store.discoverLists(form, function(res) {
      root.saving = false
      passwordField.text = ""
      if (!res.ok) { root.formError = res.error; return }
      root.discoveredAccountId = res.accountId
      root.discoveredAccount = res.account
      root.discoveredNew = root.source.indexOf("acc:") !== 0
      var have = {}
      store.lists.forEach(function(l) { if (l.source && l.source.url) have[l.source.url] = true })
      root.discovered = res.lists.map(function(l) {
        return { url: l.url, name: l.name, color: l.color, readOnly: l.readOnly, mixed: l.mixed,
                 picked: !have[l.url] && !l.mixed, already: !!have[l.url] }
      })
      // Nothing task-only found: pre-tick the shared calendars instead.
      if (!root.discovered.some(function(l) { return l.picked }))
        root.discovered = root.discovered.map(function(l) { return Object.assign({}, l, { picked: !l.already }) })
      Qt.callLater(function() { root.forceActiveFocus() })
    })
  }

  function togglePick(i) {
    if (root.discovered[i].already) return
    var next = root.discovered.slice()
    next[i] = Object.assign({}, next[i], { picked: !next[i].picked })
    root.discovered = next
  }

  function addPicked() {
    var picks = root.discovered.filter(function(l) { return l.picked && !l.already })
    if (!picks.length) { root.formError = "Pick at least one list, or create a new one below"; return }
    var ids = store.addAccountLists(root.discoveredAccountId, root.discoveredAccount, picks)
    root.discoveredNew = false
    cleanup()
    root.added(ids.length ? ids[0] : "")
    root.finished()
  }

  function createRemote() {
    var name = trim(newListField.text)
    if (!name) { root.formError = "Name the new list"; return }
    root.saving = true
    root.formError = ""
    var spec = store.suggestedColor()
    store.makeRemoteList(root.discoveredAccountId, root.discoveredAccount, name, spec, function(res) {
      root.saving = false
      if (!res.ok) { root.formError = res.error; return }
      root.discoveredNew = false
      cleanup()
      root.added(res.listId)
      root.finished()
    })
  }

  function remove() {
    if (!store || !root.editing) return
    if (!root.confirmDelete) { root.confirmDelete = true; return }
    store.removeList(root.editing.id)
    cleanup()
    root.finished()
  }

  readonly property int localTaskCount: editing && store ? store.tasks.filter(function(t) { return t.listId === root.editing.id }).length : 0
  readonly property bool editingRemote: editing !== null && store && store.isRemote(editing.id)

  PanelSectionHeader {
    text: root.isNew ? "ADD A LIST" : "LIST"
    foreground: root.fg
    fontFamily: root.fontFamily
  }

  ButtonGroup {

    focusable: false
    visible: root.isNew && !root.picking
    options: [{ value: "account", label: "From an account" }, { value: "local", label: "On this computer" }]
    value: root.kind
    foreground: root.fg
    fontFamily: root.fontFamily
    fontSize: Style.font.bodySmall
    onChanged: function(v) { root.kind = v; root.formError = "" }
  }

  // ---- name + color (local new, and edit)
  TextField {
    id: nameField
    visible: !root.isNew || root.kind === "local"
    width: parent.width
    placeholderText: "List name"
    foreground: root.fg
    font.family: root.fontFamily
  }
  Caption { visible: !root.isNew || root.kind === "local"; foreground: root.fg; fontFamily: root.fontFamily; text: "COLOR" }
  Flow {
    visible: !root.isNew || root.kind === "local"
    width: parent.width
    spacing: Style.space(8)
    Repeater {
      model: root.store ? root.store.suggestions : []
      Item {
        id: sw
        required property var modelData
        width: Style.space(26)
        height: width
        Swatch {
          anchors.centerIn: parent
          width: Style.space(18)
          swatch: sw.modelData.hex
          ring: root.colorSpec === sw.modelData.spec
          ringColor: root.fg
        }
        MouseArea { id: swMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.colorSpec = sw.modelData.spec }
        PanelToolTip { visible: swMouse.containsMouse; text: sw.modelData.label; fontFamily: root.fontFamily }
      }
    }
  }

  // ---- edit: where it lives, defaults, remove
  Text {
    visible: !root.isNew
    width: parent.width
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    text: !root.editing || !root.store ? "" : root.store.sourceLabel(root.editing.id)
      + (root.editingRemote ? "\n" + root.store.syncLine(root.editing.id) : "")
      + (root.editingRemote && root.editing.source.mixed ? "\nThis collection also holds calendar events; only its tasks are shown here." : "")
    color: root.editing && root.store && root.store.syncStatus(root.editing.id) && root.store.syncStatus(root.editing.id).error ? Color.urgent : root.dimFg
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
  Toggle {
    visible: !root.isNew
    width: parent.width
    label: "Default list for new tasks"
    description: "Where quick add puts tasks from Today, Scheduled and the other smart lists"
    checked: root.editing && root.store ? root.store.defaultListId === root.editing.id : false
    foreground: root.fg
    fontFamily: root.fontFamily
    titleSize: Style.font.body
    onClicked: if (root.store && root.editing) root.store.setPref("defaultList", checked ? "" : root.editing.id)
  }
  Toggle {
    visible: !root.isNew
    width: parent.width
    label: "Show in Today, Scheduled and All"
    checked: root.editing && root.store && root.store.listById(root.editing.id) ? root.store.listById(root.editing.id).visible !== false : true
    foreground: root.fg
    fontFamily: root.fontFamily
    titleSize: Style.font.body
    onClicked: if (root.store && root.editing) root.store.toggleList(root.editing.id)
  }

  // ---- add from an account: which one
  Caption { visible: root.isNew && root.kind === "account" && !root.picking; foreground: root.fg; fontFamily: root.fontFamily; text: "ACCOUNT" }
  Dropdown {
    visible: root.isNew && root.kind === "account" && !root.picking
    width: parent.width
    showLabel: false
    value: root.source
    options: root.accountOptions
    foreground: root.fg
    fontFamily: root.fontFamily
    onChanged: function(v) { root.source = v; root.formError = "" }
  }
  Text {
    visible: root.isNew && root.kind === "account" && !root.picking && root.source !== "new"
    width: parent.width
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    text: "Uses the password already in your keyring for this account."
    color: root.faintFg
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
  Dropdown {
    visible: root.signingIn
    width: parent.width
    showLabel: false
    value: root.provider
    options: root.providerOptions
    foreground: root.fg
    fontFamily: root.fontFamily
    onChanged: function(v) { root.provider = v; value = v }
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

  // ---- add from an account: pick lists
  Caption { visible: root.picking; foreground: root.fg; fontFamily: root.fontFamily; text: "CHOOSE LISTS" }
  Repeater {
    model: root.picking ? root.discovered : []
    Rectangle {
      id: pickRow
      required property var modelData
      required property int index
      width: root.width
      height: Style.space(30)
      radius: Style.cornerRadius
      color: pickMouse.containsMouse && !modelData.already ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"
      Text {
        id: pickCheck
        x: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        text: pickRow.modelData.picked || pickRow.modelData.already ? "󰄲" : "󰄱"
        color: pickRow.modelData.picked && !pickRow.modelData.already ? Color.accent : root.faintFg
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
      }
      Column {
        anchors.left: pickCheck.right
        anchors.leftMargin: Style.space(10)
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        Text {
          width: parent.width
          elide: Text.ElideRight
          textFormat: Text.PlainText
          text: pickRow.modelData.name + (pickRow.modelData.readOnly ? "  (read-only)" : "") + (pickRow.modelData.already ? "  (added)" : "")
          color: pickRow.modelData.already ? root.faintFg : root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
        Text {
          visible: pickRow.modelData.mixed
          textFormat: Text.PlainText
          text: "calendar that also holds tasks"
          color: root.faintFg
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
      MouseArea {
        id: pickMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: pickRow.modelData.already ? Qt.ArrowCursor : Qt.PointingHandCursor
        onClicked: root.togglePick(pickRow.index)
      }
    }
  }
  Text {
    visible: root.picking && root.discovered.length === 0
    width: parent.width
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    text: "This account has no collections that can hold tasks yet. Create one below."
    color: root.dimFg
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
  Caption { visible: root.picking; foreground: root.fg; fontFamily: root.fontFamily; text: "OR CREATE A NEW LIST ON THE SERVER" }
  Row {
    visible: root.picking
    width: parent.width
    spacing: Style.space(8)
    TextField {
      id: newListField
      width: parent.width - createBtn.width - parent.spacing
      placeholderText: "e.g. Tasks, Groceries"
      foreground: root.fg
      font.family: root.fontFamily
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.createRemote(); event.accepted = true }
      }
    }
    Button {
      id: createBtn
      text: "Create"
      enabled: !root.saving
      bordered: true
      foreground: root.fg
      fontFamily: root.fontFamily
      onClicked: root.createRemote()
    }
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

  Flow {
    width: parent.width
    spacing: Style.space(8)
    Button {
      text: root.saving ? "Working…"
        : !root.isNew ? "Save"
        : root.kind === "local" ? "Add list"
        : root.picking ? "Add " + root.discovered.filter(function(l) { return l.picked && !l.already }).length + " lists"
        : root.source === "new" ? "Connect" : "Find lists"
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
      visible: root.editingRemote
      text: "Sync now"
      enabled: root.store && !root.store.syncing
      bordered: true
      foreground: root.fg
      fontFamily: root.fontFamily
      onClicked: root.store.syncList(root.editing.id)
    }
  }

  Button {
    visible: !root.isNew
    text: root.confirmDelete
      ? (root.editingRemote ? "Really remove? (nothing is deleted on the server)" : "Really delete it and its " + root.localTaskCount + " tasks?")
      : (root.editingRemote ? "Remove list" : "Delete list")
    bordered: true
    foreground: root.confirmDelete ? Color.urgent : root.fg
    fontFamily: root.fontFamily
    onClicked: root.remove()
  }
}
