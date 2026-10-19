import QtQuick
import qs.Commons
import qs.Ui

// Add address books (from an account already connected for calendars, or
// a new sign-in) and the settings form for one address book. Emits
// finished() when done; added(bookId) after adding.
Column {
  id: root

  property var store: null
  property color fg: Color.foreground
  property string fontFamily: Style.font.family

  signal finished()
  signal added(string bookId)

  property var editingBook: null
  property string source: "new"           // an account id, or "new" for a new sign-in
  property string provider: "icloud"
  property var discovered: []             // [{url, name, readOnly, picked}]
  property string discoveredAccountId: ""
  property bool discoveredNew: false
  property string discoveredServer: ""
  property string formError: ""
  property bool saving: false
  property bool confirmDelete: false

  readonly property bool isNew: editingBook === null
  readonly property bool picking: isNew && discovered.length > 0
  readonly property bool signingIn: isNew && !picking && source === "new"
  readonly property color dimFg: Qt.darker(fg, 1.5)
  readonly property color faintFg: Qt.darker(fg, 1.9)

  // One entry per login: the same user on the same server can be in the
  // list twice (connected again for another calendar); either password works.
  readonly property var accountOptions: {
    var out = [], seen = {}
    var accs = store ? store.accounts : []
    for (var i = 0; i < accs.length; i++) {
      var host = String(accs[i].server || "").replace(/^[a-z]+:\/\//i, "").split(/[\/:]/)[0]
      var key = accs[i].provider + "|" + host + "|" + accs[i].username
      if (seen[key]) continue
      seen[key] = true
      out.push({ value: accs[i].id, label: store.providerName(accs[i].provider) + " · " + accs[i].username
        + (host && accs[i].provider !== "icloud" && accs[i].provider !== "fastmail" ? " · " + host.split(".")[0] : "") })
    }
    out.push({ value: "new", label: "Sign in to another account…" })
    return out
  }
  readonly property var providerOptions: [
    { value: "icloud", label: "iCloud" },
    { value: "fastmail", label: "Fastmail" },
    { value: "nextcloud", label: "Nextcloud" },
    { value: "caldav", label: "Other CardDAV server" }
  ]
  readonly property var providerHelp: ({
    icloud: "Use your Apple ID email and an app-specific password: account.apple.com → Sign-In and Security → App-Specific Passwords.",
    fastmail: "Use your Fastmail address and an app password with CardDAV access: Settings → Privacy & Security → Manage app passwords.",
    nextcloud: "Server is your Nextcloud address (e.g. cloud.example.com). Create an app password under Personal settings → Security.",
    caldav: "Enter the CardDAV server or principal URL and your username/password (an app password if the service offers one)."
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
    root.discoveredNew = false
    passwordField.text = ""
  }

  function openNew() {
    reset()
    root.editingBook = null
    root.source = store && store.accounts.length ? store.accounts[0].id : "new"
    usernameField.text = ""
    serverField.text = ""
    Qt.callLater(function() { if (root.source === "new") usernameField.forceActiveFocus(); else root.forceActiveFocus() })
  }

  function openEdit(book) {
    reset()
    root.editingBook = book
    nameField.text = book.name || ""
    Qt.callLater(function() { nameField.forceActiveFocus(); nameField.selectAll() })
  }

  function cleanup() {
    // Signed in to a new account but added nothing: drop its password.
    if (root.discoveredNew && root.discoveredAccountId !== "" && store) store.abandonAccount(root.discoveredAccountId)
    reset()
    root.editingBook = null
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
      if (name === "") { root.formError = "Give the address book a name"; return }
      store.renameAddressBook(root.editingBook.id, name)
      cleanup()
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
      if (user === "" || passwordField.text === "") { root.formError = "Enter the username and app password"; return }
      var server = trim(serverField.text)
      if ((root.provider === "nextcloud" || root.provider === "caldav") && server === "") { root.formError = "Enter the server address"; return }
      if (root.provider === "nextcloud" && server.indexOf("remote.php") === -1) server = server.replace(/\/+$/, "") + "/remote.php/dav/"
      form = { provider: root.provider, server: server, username: user, password: passwordField.text }
    } else form = { accountId: root.source }
    root.saving = true
    root.formError = ""
    store.discoverBooks(form, function(res) {
      root.saving = false
      passwordField.text = ""
      if (!res.ok) { root.formError = res.error; return }
      root.discoveredAccountId = res.accountId
      root.discoveredNew = root.source === "new"
      root.discoveredServer = form.server || ""
      var have = {}
      for (var i = 0; i < store.addressBooks.length; i++) have[store.addressBooks[i].url] = true
      root.discovered = res.books.map(function(b) {
        return { url: b.url, name: b.name, readOnly: b.readOnly, picked: !have[b.url], already: !!have[b.url] }
      })
      Qt.callLater(function() { root.forceActiveFocus() })
    })
  }

  function togglePick(index) {
    if (root.discovered[index].already) return
    var next = root.discovered.slice()
    next[index] = Object.assign({}, next[index], { picked: !next[index].picked })
    root.discovered = next
  }

  function addPicked() {
    var picks = root.discovered.filter(function(b) { return b.picked && !b.already })
    if (picks.length === 0) { root.formError = "Pick at least one address book"; return }
    var newAccount = root.discoveredNew
      ? { provider: root.provider, server: root.discoveredServer, username: trim(usernameField.text) }
      : null
    var before = store.addressBooks.length
    store.addAddressBooks(root.discoveredAccountId, newAccount, picks)
    var first = store.addressBooks.length > before ? store.addressBooks[before].id : ""
    root.discoveredNew = false   // the account is kept now
    cleanup()
    root.added(first)
    root.finished()
  }

  function remove() {
    if (!store || !root.editingBook) return
    if (!root.confirmDelete) { root.confirmDelete = true; return }
    store.removeAddressBook(root.editingBook.id)
    cleanup()
    root.finished()
  }

  PanelSectionHeader {
    text: root.isNew ? "ADD AN ADDRESS BOOK" : "ADDRESS BOOK"
    foreground: root.fg
    fontFamily: root.fontFamily
  }

  // ---- edit
  TextField {
    id: nameField
    visible: !root.isNew
    width: parent.width
    placeholderText: "Address book name"
    foreground: root.fg
    font.family: root.fontFamily
  }
  Text {
    visible: !root.isNew
    width: parent.width
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    text: root.editingBook && root.store
      ? root.store.bookLabel(root.editingBook.id) + "\n" + root.store.bookCount(root.editingBook.id) + " contacts · " + root.store.bookSyncLine(root.editingBook.id)
      : ""
    color: root.editingBook && root.store && root.store.bookStatus(root.editingBook.id) && root.store.bookStatus(root.editingBook.id).error ? Color.urgent : root.dimFg
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
  Text {
    visible: !root.isNew
    width: parent.width
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    text: "The name is only changed here, not on the server."
    color: root.faintFg
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  // ---- add: which account
  Caption { visible: root.isNew && !root.picking; foreground: root.fg; fontFamily: root.fontFamily; text: "ACCOUNT" }
  Dropdown {
    visible: root.isNew && !root.picking
    width: parent.width
    showLabel: false
    value: root.source
    options: root.accountOptions
    foreground: root.fg
    fontFamily: root.fontFamily
    onChanged: function(v) { root.source = v; root.formError = "" }
  }
  Text {
    visible: root.isNew && !root.picking && root.source !== "new"
    width: parent.width
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    text: "Uses the password already in your keyring for this account."
    color: root.faintFg
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  // ---- add: new sign-in
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

  // ---- add: pick books
  Caption { visible: root.picking; foreground: root.fg; fontFamily: root.fontFamily; text: "CHOOSE ADDRESS BOOKS" }
  Repeater {
    model: root.picking ? root.discovered : []

    Rectangle {
      id: pickRow
      required property var modelData
      required property int index
      width: root.width
      height: Style.space(28)
      radius: Style.cornerRadius
      color: pickMouse.containsMouse && !modelData.already ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"

      Text {
        id: pickCheck
        x: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        text: pickRow.modelData.picked || pickRow.modelData.already ? "󰄲" : "󰄱"
        color: pickRow.modelData.already ? root.faintFg : pickRow.modelData.picked ? Color.accent : root.faintFg
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
        text: pickRow.modelData.name + (pickRow.modelData.readOnly ? "  (read-only)" : "") + (pickRow.modelData.already ? "  (added)" : "")
        color: pickRow.modelData.already ? root.faintFg : root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
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
      text: root.saving ? "Signing in…"
        : !root.isNew ? "Save"
        : root.picking ? "Add " + root.discovered.filter(function(b) { return b.picked && !b.already }).length + " address books"
        : root.source === "new" ? "Connect" : "Find address books"
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
      visible: !root.isNew
      text: "Sync now"
      enabled: root.store && !root.store.contactsSyncing
      bordered: true
      foreground: root.fg
      fontFamily: root.fontFamily
      onClicked: root.store.syncContacts()
    }
  }

  Button {
    visible: !root.isNew
    text: root.confirmDelete ? "Really remove? (nothing is deleted on the server)" : "Remove address book"
    bordered: true
    foreground: root.confirmDelete ? Color.urgent : root.fg
    fontFamily: root.fontFamily
    onClicked: root.remove()
  }
}
