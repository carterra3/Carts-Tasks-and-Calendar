//@ pragma OmarchyLoadPatch
import QtQuick
import QtTest
import Quickshell
import qs.Commons
import "Events.js" as Events

// Synthetic-mouse drag tests through the real TimeGrid / MonthGrid: move,
// resize and drag-create in the week grid, all-day bars, month chips and
// bars. Run by tests/run_qml.py on tests/qml/seed.json.
ShellRoot {
  id: h
  property var log: []
  property string range: ""
  property string recurringMove: ""
  function out(s) { console.log("D|" + s) }

  Store { id: store }

  FloatingWindow {
    id: w
    title: "DragTest"
    color: Color.background
    implicitWidth: 1100; implicitHeight: 1600
    TimeGrid {
      id: tg
      width: 1100; height: 560
      store: store
      days: 7
      startKey: "2026-10-18"
      // Today outside the shown week, so the grid opens just before the
      // first event (08:00) instead of an hour before the wall clock.
      todayKey: "2026-10-12"
      hourHeight: 40
      onEventMoved: function(ev, ch) { h.out("tg moved|" + ev.title + "|" + ch.start + "|" + ch.end + "|recurring=" + !!ev.recurring); if (ev.recurring) h.recurringMove = ch.start; else store.moveEvent(ev, ch) }
      onRangeSelected: function(k, a, b) { h.range = k + " " + a + "-" + b; h.out("tg range|" + h.range) }
      onEventPicked: function(ev) { h.out("tg picked|" + ev.title) }
    }
    MonthGrid {
      id: mg
      y: 580
      store: store
      year: 2026; month: 9; weekStart: 0
      cellWidth: 140; cellHeight: 140; maxChips: 6
      todayKey: "2026-10-19"
      onEventMoved: function(ev, ch) { h.out("mg moved|" + ev.title + "|" + ch.start + "|" + ch.end); store.moveEvent(ev, ch) }
      onEventPicked: function(ev) { h.out("mg picked|" + ev.title) }
    }
  }

  TestCase { id: tc; name: "drag"; when: false }

  function walk(item, pred) {
    if (!item) return null
    if (pred(item)) return item
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) { var r = walk(kids[i], pred); if (r) return r }
    if (item.contentItem && item.contentItem !== item) return walk(item.contentItem, pred)
    return null
  }
  function block(title) { return walk(tg, function(it) { return it.modelData && it.modelData.ev && it.modelData.ev.title === title && it.modelData.cols !== undefined }) }
  function laneBar(title) { return walk(tg, function(it) { return it.modelData && it.modelData.ev && it.modelData.ev.title === title && it.modelData.row !== undefined }) }
  function dayCol(key) { return walk(tg, function(it) { return it.modelData === key && it.laid !== undefined }) }
  function chip(title) { return walk(mg, function(it) { return it.modelData && it.modelData.title === title && it.tint !== undefined }) }
  function mbar(title) { return walk(mg, function(it) { return it.modelData && it.modelData.ev && it.modelData.ev.title === title && it.modelData.row !== undefined }) }
  function ev(uid) { for (var i = 0; i < store.events.length; i++) if (store.events[i].uid === uid) return store.events[i]; return null }
  function check(name, ok, detail) { h.out((ok ? "PASS " : "FAIL ") + name + (detail ? " | " + detail : "")) }
  function drag(item, x, y, dx, dy) {
    tc.mousePress(item, x, y)
    var steps = 12
    for (var i = 1; i <= steps; i++) tc.mouseMove(item, x + dx * i / steps, y + dy * i / steps, 5)
    tc.mouseRelease(item, x + dx, y + dy, Qt.LeftButton, Qt.NoModifier, 20)
  }

  property int step: 0
  Timer {
    id: ticker
    interval: 700; repeat: true; running: store.ready
    onTriggered: {
      var colW = tg.columnWidth
      var s = h.step++
      if (s === 0) {
        var b = block("Dentist")
        if (!b) { h.check("find Dentist", false); return }
        h.drag(b, b.width / 2, b.height / 2, colW, 40)          // +1 day, +1 hour
      } else if (s === 1) {
        var e = h.ev("t5")
        h.check("move timed", e.start === "2026-10-21T09:30" && e.end === "2026-10-21T10:30", e.start + " " + e.end)
        var b2 = block("Dentist")
        h.drag(b2, b2.width / 2, b2.height - 3, 0, 20)          // bottom edge +30 min
      } else if (s === 2) {
        var e2 = h.ev("t5")
        h.check("resize", e2.start === "2026-10-21T09:30" && e2.end === "2026-10-21T11:00", e2.start + " " + e2.end)
        var b3 = block("Dentist")
        tc.mouseClick(b3, b3.width / 2, 8)                       // a click still opens it
      } else if (s === 3) {
        var col = dayCol("2026-10-24")
        h.drag(col, col.width / 2, 12 * 40 + 4, 0, 80)           // 12:00 -> 14:00 on Saturday (in view)
      } else if (s === 4) {
        h.check("drag-create reports the range", h.range === "2026-10-24 720-840", h.range)
        var lb = laneBar("Conference")
        h.drag(lb, 20, lb.height / 2, colW, 0)                  // +1 day
      } else if (s === 5) {
        var c = h.ev("t2")
        h.check("lane bar +1 day", c.start === "2026-10-22" && c.end === "2026-10-24", c.start + " " + c.end)
        var st = walk(tg, function(it) { return it.modelData && it.modelData.ev && it.modelData.ev.title === "Standup" && it.modelData.ev.start.indexOf("2026-10-22") === 0 })
        h.drag(st, st.width / 2, st.height / 2, 0, 40)          // repeating: reported, not saved
      } else if (s === 6) {
        h.check("repeating event drag is reported, not saved", h.recurringMove === "2026-10-22T10:00" && h.ev("s1").start === "2026-10-05T09:00",
                h.recurringMove + " / " + h.ev("s1").start)
        var ch = h.chip("1:1 with Sam")
        h.out("chip found=" + !!ch + " visible=" + (ch && ch.visible) + " size=" + (ch && (ch.width + "x" + ch.height)) + " parentVisible=" + (ch && ch.parent.visible))
        tc.mousePress(ch, 20, ch.height / 2)
        for (var i = 1; i <= 12; i++) tc.mouseMove(ch, 20 + 284 * i / 12, ch.height / 2, 5)
        h.out("mid-drag dropKey=" + mg.dropKey + " dragged=" + (mg.draggedEv && mg.draggedEv.title))
        tc.mouseRelease(ch, 304, ch.height / 2, Qt.LeftButton, Qt.NoModifier, 20)
      } else if (s === 7) {
        var o = h.ev("t6")
        h.check("month chip +2 days", o.start === "2026-10-22T13:00" && o.end === "2026-10-22T13:30", o.start + " " + o.end)
        var lake = h.mbar("Lake trip")
        h.drag(lake, 30, lake.height / 2, 0, mg.cellHeight + mg.cellSpacing)   // a week later
      } else if (s === 8) {
        var l = h.ev("t1")
        h.check("month bar +7 days", l.start === "2026-10-23" && l.end === "2026-10-27", l.start + " " + l.end)
        h.out("done"); Qt.quit()
      }
    }
  }
  Timer { interval: 30000; running: true; onTriggered: { h.out("timeout"); Qt.quit() } }
}
