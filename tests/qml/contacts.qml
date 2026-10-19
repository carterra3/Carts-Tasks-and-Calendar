//@ pragma OmarchyLoadPatch
import QtQuick
import Quickshell
import qs.Commons
import "Contacts.js" as Contacts

// AddressBookEditor + ContactEditor + Store against Radicale: add books
// from an existing account, create / edit / move / delete contacts,
// rename and remove a book. Run by tests/run_qml.py.
ShellRoot {
  id: h
  Store { id: store }
  FloatingWindow { visible: false; implicitWidth: 400; implicitHeight: 900
    Column {
      AddressBookEditor { id: books; width: 380; store: store; onFinished: h.out("books finished") }
      ContactEditor { id: editor; width: 380; store: store; onFinished: function(key) { h.lastKey = key; h.out("editor finished key=" + key) } }
    }
  }
  property string lastKey: ""
  function out(s) { console.log("Z|" + s) }
  function check(ok, what) { out((ok ? "PASS " : "FAIL ") + what) }
  function named(n) { return store.contacts.filter(function(c) { return Contacts.displayName(c) === n }) }
  property int step: 0
  Timer { id: settle; interval: 2500; onTriggered: h.next() }
  Timer { interval: 1500; running: store.ready; onTriggered: settle.restart() }
  Timer { interval: 60000; running: true; onTriggered: { h.out("timeout " + h.step); Qt.quit() } }
  function next() {
    var s = h.step++
    settle.restart()
    if (s === 0) {
      // clean slate for address books
      store.addressBooks.slice().forEach(function(b) { store.removeAddressBook(b.id) })
      books.openNew()
      check(books.source === "acc-qml", "add form defaults to the existing account (" + books.source + ")")
      books.save()
    } else if (s === 1) {
      check(books.picking && books.discovered.length === 2, "discovered " + JSON.stringify(books.discovered.map(function(b) { return b.name })))
      books.save()
    } else if (s === 2) {
      check(store.addressBooks.length === 2, "two books added")
      check(store.contacts.length === 6, "synced 6 contacts, got " + store.contacts.length)
      var mary = h.named("Mary Garcia")[0]
      check(mary && mary.phones.length === 2 && mary.phones[0].type === "cell" && mary.birthday === "1990-03-14", "Mary parsed " + JSON.stringify(mary && mary.phones))
      var bob = h.named("Bob Abbott")[0]
      check(bob && bob.photo.indexOf("data:image/png;base64,") === 0, "Bob photo")
      var personal = store.addressBooks.filter(function(b) { return b.name === "Personal" })[0]
      h.personal = personal.id
      h.work = store.addressBooks.filter(function(b) { return b.name !== "Personal" })[0].id
      editor.openNew(personal.id)
      editor.form.given = "Test"; editor.form.family = "Person"
      editor.form.phones[0].value = "555-1234"
      editor.form.emails[0].value = "bad"
      editor.save()
      check(editor.formError.indexOf("not an email") !== -1, "rejects bad email: " + editor.formError)
      editor.form.emails[0].value = "test@example.com"
      editor.addRow("addresses", { type: "work", street: "9 Elm", city: "Salem", region: "OR", code: "97301", country: "" })
      editor.form.birthday = "07-04"
      editor.form.notes = "line one\nline two"
      editor.save()
    } else if (s === 3) {
      var t = h.named("Test Person")[0]
      check(!!t && h.lastKey === Contacts.keyOf(t), "created, key returned")
      check(t && t.addresses.length === 1 && t.addresses[0].city === "Salem" && t.birthday === "--07-04" && t.notes === "line one\nline two", "fields round-trip " + JSON.stringify(t && [t.addresses, t.birthday, t.notes]))
      editor.openEdit(t)
      editor.form.title = "Tester"
      editor.form.bookId = h.work
      editor.save()
    } else if (s === 4) {
      var t2 = h.named("Test Person")
      check(t2.length === 1 && t2[0].bookId === h.work && t2[0].title === "Tester", "moved to work book with edit " + JSON.stringify(t2.map(function(c) { return [c.bookId, c.title] })))
      editor.openEdit(t2[0])
      editor.remove()
      check(editor.confirmDelete, "delete asks first")
      editor.remove()
    } else if (s === 5) {
      check(h.named("Test Person").length === 0, "deleted")
      var mary = h.named("Mary Garcia")[0]
      editor.openEdit(mary)
      editor.form.notes = "Met at the conference.\nLikes coffee now."
      editor.save()
    } else if (s === 6) {
      var m = h.named("Mary Garcia")[0]
      check(m.notes === "Met at the conference.\nLikes coffee now." && m.emails[0].value === "mary@example.com" && m.phones.length === 2, "edit keeps other fields")
      store.renameAddressBook(h.work, "Office")
      check(store.bookById(h.work).name === "Office", "rename")
      books.openEdit(store.bookById(h.work))
      books.remove(); books.remove()
    } else if (s === 7) {
      check(store.addressBooks.length === 1 && store.contacts.length === 4, "removed book: books=" + store.addressBooks.length + " contacts=" + store.contacts.length)
      check(store.accounts.some(function(a) { return a.id === "acc-qml" }), "account kept (still used)")
      h.out("done"); Qt.quit()
    }
  }
  property string personal: ""
  property string work: ""
}
