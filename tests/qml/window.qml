//@ pragma OmarchyLoadPatch
import QtQuick
import QtTest
import Quickshell
import qs.Commons

// The app window as a whole: keyboard shortcuts, the calendar/contacts
// switch, the drawers, and the contacts list/search wiring. Run by
// tests/run_qml.py (address books are added through the store first).
ShellRoot {
  id: h
  function out(s) { console.log("W|" + s) }
  function check(name, ok, detail) { h.out((ok ? "PASS " : "FAIL ") + name + (detail ? " | " + detail : "")) }

  Store { id: store }

  CalendarWindow {
    id: win
    store: store
    visible: true
  }

  TestCase { id: tc; name: "window"; when: false }

  function key(k, text) { tc.keyClick(k) }
  function walk(item, pred) {
    if (!item) return null
    if (pred(item)) return item
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) { var r = walk(kids[i], pred); if (r) return r }
    if (item.contentItem && item.contentItem !== item) return walk(item.contentItem, pred)
    return null
  }
  readonly property var view: walk(win.contentItem, function(it) { return it.list !== undefined && it.selectRequested !== undefined })
  readonly property var search: walk(win.contentItem, function(it) { return it.placeholderText !== undefined && String(it.placeholderText).indexOf("Search contacts") === 0 })

  property int step: 0
  Timer {
    id: ticker
    interval: 900; repeat: true; running: store.ready
    // After a long frame (the year view builds twelve months at once) the
    // timer fires again right away; keep a full interval between steps so
    // the keys of the last step have been handled.
    property real last: 0
    onTriggered: {
      if (Date.now() - last < 850) return
      last = Date.now()
      var s = h.step++
      if (s === 0) {
        win.present("2026-10-20", "month")
        h.check("starts in calendar mode", win.mode === "calendar" && !win.contactsMode, win.mode)
        h.key(Qt.Key_W)
        h.key(Qt.Key_BracketRight)
      } else if (s === 1) {
        h.check("w = week view, ] = next week", win.view === "week" && win.cursorKey === "2026-10-27", win.view + " " + win.cursorKey)
        h.key(Qt.Key_Y)
      } else if (s === 2) {
        h.check("y = year view", win.view === "year", win.view)
        h.key(Qt.Key_T)
        h.key(Qt.Key_N)
      } else if (s === 3) {
        h.check("n opens the event drawer", win.drawer === "event", win.drawer)
        h.key(Qt.Key_Escape)
      } else if (s === 4) {
        h.check("Esc closes the drawer", win.drawer === "", win.drawer)
        // Address books straight through the store (the add form is covered by contacts.qml).
        store.discoverBooks({ accountId: "acc-qml" }, function(res) {
          if (!res.ok) { h.check("discover books", false, res.error); return }
          store.addAddressBooks("acc-qml", null, res.books)
        })
      } else if (s === 5) {
        // Regression: a closed editor's text field used to keep the keys.
        h.key(Qt.Key_M)
        h.key(Qt.Key_C)
      } else if (s === 6) {
        h.check("keys work after closing the event drawer", win.view === "month", win.view)
        h.check("c switches to contacts", win.contactsMode && store.pref("windowMode", "") === "contacts", win.mode)
        h.check("contacts loaded", store.contacts.length === 6, String(store.contacts.length))
        h.check("first contact selected", h.view && h.view.current && h.view.current.fn === "Bob Abbott", h.view && h.view.current && h.view.current.fn)
        h.key(Qt.Key_J); h.key(Qt.Key_J)
      } else if (s === 7) {
        h.check("j moves down the list", h.view.current.fn === "Mary Garcia", h.view.current.fn)
        h.key(Qt.Key_Slash)
      } else if (s === 8) {
        h.check("/ focuses search", h.search && h.search.activeFocus)
        "acme".split("").forEach(function(ch) { tc.keyClick(ch) })
      } else if (s === 9) {
        h.check("search filters", h.view.list.length === 2 && h.view.list.every(function(c) { return c.org === "Acme Corp" }),
                h.view.list.map(function(c) { return c.fn }).join(", "))
        h.check("selection follows the filter", h.view.current && h.view.current.org === "Acme Corp", h.view.current && h.view.current.fn)
        h.key(Qt.Key_Escape)    // clears search, back to the list
        h.key(Qt.Key_J)
      } else if (s === 10) {
        h.check("Esc in search clears it and gives the keys back", !h.search.activeFocus && h.search.text === "" && h.view.list.length === 6, "'" + h.search.text + "'")
        h.check("j works again after the search", h.view.currentIndex === 3, h.view.current && h.view.current.fn)
        var work = store.addressBooks.filter(function(b) { return b.name === "Work contacts" })[0]
        win.contactsBook = work.id
      } else if (s === 11) {
        h.check("book filter", h.view.list.length === 2 && h.view.list.every(function(c) { return c.bookId === win.contactsBook }), String(h.view.list.length))
        h.key(Qt.Key_E)
      } else if (s === 12) {
        h.check("e edits the selected contact", win.drawer === "contact", win.drawer)
        h.key(Qt.Key_Escape)
      } else if (s === 13) {
        h.check("Esc cancels the contact editor", win.drawer === "", win.drawer)
        h.key(Qt.Key_N)
      } else if (s === 14) {
        h.check("n opens a new contact in the filtered book", win.drawer === "contact" && h.walk(win.contentItem, function(it) { return it.form !== undefined && it.isNew === true && it.form.bookId === win.contactsBook }) !== null)
        h.key(Qt.Key_Escape)
        h.key(Qt.Key_C)
      } else if (s === 15) {
        h.check("Esc closes the new-contact form", win.drawer === "", win.drawer)
        h.check("c goes back to the calendar", win.mode === "calendar", win.mode)
        h.out("done"); Qt.quit()
      }
    }
  }
  Timer { interval: 45000; running: true; onTriggered: { h.out("timeout " + h.step); Qt.quit() } }
}
