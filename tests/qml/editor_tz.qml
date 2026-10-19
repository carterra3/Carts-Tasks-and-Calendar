//@ pragma OmarchyLoadPatch
import QtQuick
import Quickshell
import qs.Commons
import "Events.js" as Events

// EventEditor + Store: time zones on local and CalDAV events, and the
// wall time of a zoned series across both DST changes. Run by
// tests/run_qml.py (TZ=America/Chicago).
ShellRoot {
  id: h
  Store { id: store }
  FloatingWindow { visible: false; implicitWidth: 400; implicitHeight: 900
    EventEditor { id: editor; width: 380; store: store; use24h: true; onFinished: settle.restart() } }
  function out(s) { console.log("Z|" + s) }
  function find(title, cal) { return store.allEvents.filter(function(e) { return e.title === title && (!cal || e.calendarId === cal) }).sort(function(a, b) { return a.start < b.start ? -1 : 1 }) }
  property int step: 0
  Timer { id: settle; interval: 1500; onTriggered: h.next() }
  Timer { interval: 2000; running: store.ready; onTriggered: { store.ensureZones(["Europe/Paris"]); settle.restart() } }
  Timer { interval: 40000; running: true; onTriggered: { h.out("timeout " + h.step); Qt.quit() } }
  function next() {
    var s = h.step++
    if (s === 0) {
      h.out("paris table loaded=" + !!store.zoneTable("Europe/Paris") + " local=" + store.localZone)
      editor.openNew("2026-10-20", 600)
      editor.formTz = "Europe/Paris"
      editor.fill({ title: "Paris call", calendarId: "cal-local", allDay: false, startDate: "2026-10-20", endDate: "2026-10-20",
                    startTime: "18:00", endTime: "19:00", location: "", notes: "", rrule: "FREQ=DAILY;COUNT=14" })
      h.out("hint=" + editor.localHint())
      editor.save()
    } else if (s === 1) {
      var o = h.find("Paris call", "cal-local")
      h.out((o.length === 14 && o[0].tz === "Europe/Paris" ? "PASS" : "FAIL") + " local tz series count=" + o.length + " tz=" + (o[0] && o[0].tz))
      var times = o.map(function(e) { return e.start.substr(5) })
      // Paris 18:00: CDT 11:00 until Oct 24, 12:00 Oct 25-31 (EU back on CET), 11:00 from Nov 1 (US back on CST)
      var ok = times[0] === "10-20T11:00" && times[5] === "10-25T12:00" && times[11] === "10-31T12:00" && times[12] === "11-01T11:00"
      h.out((ok ? "PASS" : "FAIL") + " wall time kept across both DST changes | " + times.join(" "))
      var f = editor.zoneForm(o[6])
      h.out((f.startTime === "18:00" && f.endTime === "19:00" ? "PASS" : "FAIL") + " editor shows Paris time | " + f.startDate + " " + f.startTime + "-" + f.endTime)
      editor.openNew("2026-10-21", 600)
      editor.formTz = "Asia/Tokyo"
      store.ensureZones(["Asia/Tokyo"])
      settle.restart()
    } else if (s === 2) {
      editor.fill({ title: "Tokyo standup", calendarId: "cal-work", allDay: false, startDate: "2026-10-22", endDate: "2026-10-22",
                    startTime: "09:00", endTime: "09:30", location: "", notes: "", rrule: "" })
      editor.save()
    } else if (s === 3) {
      var t = h.find("Tokyo standup", "cal-work")
      // 09:00 JST = 00:00 UTC = 19:00 CDT the day before
      h.out((t.length === 1 && t[0].start === "2026-10-21T19:00" && t[0].tz === "Asia/Tokyo" ? "PASS" : "FAIL") + " caldav tz event | " + JSON.stringify(t.map(function(e) { return [e.start, e.end, e.tz] })))
      editor.openEdit(t[0])
      h.out("edit formTz=" + editor.formTz)
      editor.remove()   // asks to confirm first
      editor.remove()
    } else if (s === 4) {
      h.out((h.find("Tokyo standup", "cal-work").length === 0 ? "PASS" : "FAIL") + " caldav tz event deleted")
      var p = h.find("Paris call", "cal-local")[0]
      editor.openEdit(p); editor.remove(); editor.chooseScope("all")
    } else if (s === 5) {
      h.out((h.find("Paris call").length === 0 && !store.events.some(function(e) { return e.title === "Paris call" }) ? "PASS" : "FAIL") + " whole local series deleted")
      h.out("done"); Qt.quit()
    }
  }
}
