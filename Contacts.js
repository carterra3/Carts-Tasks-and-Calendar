// Pure helpers for the Contacts view: search, sections, labels and the
// editor's form <-> contact record conversion. Qt-free so tests run under
// node (tests/contacts.test.js). Records come from sync/vcard.py:
// { uid, fn, given, family, additional, prefix, suffix, org, title,
//   emails: [{type, value}], phones: [{type, value}],
//   addresses: [{type, street, city, region, code, country}], urls: [],
//   birthday ("yyyy-MM-dd" | "--MM-dd" | ""), notes, photo,
//   href, etag, bookId, readOnly }

var EMAIL_TYPES = ["home", "work", "other"]
var PHONE_TYPES = ["cell", "home", "work", "main", "fax", "other"]
var ADDRESS_TYPES = ["home", "work", "other"]

function trim(s) { return String(s === undefined || s === null ? "" : s).replace(/^\s+|\s+$/g, "") }

function typeLabel(t) {
  return ({ cell: "mobile", home: "home", work: "work", main: "main", fax: "fax", other: "other" })[t] || "other"
}

function displayName(c) {
  if (!c) return ""
  var parts = [c.prefix, c.given, c.additional, c.family, c.suffix].map(trim).filter(function(x) { return x })
  return parts.join(" ") || trim(c.fn) || trim(c.org) || (c.emails && c.emails.length ? trim(c.emails[0].value) : "")
}

// Sort key: family name first when there is one, like most address books.
function sortKey(c) {
  var fam = trim(c && c.family), giv = trim(c && c.given)
  var k = fam ? fam + " " + giv : displayName(c)
  return k.toLowerCase()
}

function compare(a, b) {
  var x = sortKey(a), y = sortKey(b)
  return x < y ? -1 : x > y ? 1 : 0
}

// "A".."Z", or "#" for anything else (digits, symbols, other scripts).
function sectionOf(c) {
  var ch = sortKey(c).charAt(0).toUpperCase()
  var plain = ch.normalize ? ch.normalize("NFD").charAt(0) : ch
  return /[A-Z]/.test(plain) ? plain : "#"
}

function initials(c) {
  var g = trim(c && c.given), f = trim(c && c.family)
  var s = (g ? g.charAt(0) : "") + (f ? f.charAt(0) : "")
  if (!s) {
    var words = displayName(c).split(/\s+/).filter(function(w) { return w })
    s = words.slice(0, 2).map(function(w) { return w.charAt(0) }).join("")
  }
  return s.toUpperCase() || "?"
}

function _haystack(c) {
  var bits = [displayName(c), c.fn, c.org, c.title, c.notes]
  ;(c.emails || []).forEach(function(e) { bits.push(e.value) })
  ;(c.phones || []).forEach(function(p) { bits.push(p.value, String(p.value || "").replace(/\D/g, "")) })
  ;(c.addresses || []).forEach(function(a) { bits.push(a.street, a.city, a.region, a.code, a.country) })
  return bits.map(trim).join("\n").toLowerCase()
}

// Every whitespace-separated word of the query must appear somewhere.
function matches(c, query) {
  var words = trim(query).toLowerCase().split(/\s+/).filter(function(w) { return w })
  if (!words.length) return true
  var hay = _haystack(c)
  for (var i = 0; i < words.length; i++) {
    var w = words[i]
    if (hay.indexOf(w) !== -1) continue
    var digits = w.replace(/\D/g, "")
    if (digits.length >= 3 && digits.length === w.replace(/[\s()+.-]/g, "").length && hay.indexOf(digits) !== -1) continue
    return false
  }
  return true
}

// contacts filtered to one book ("" = all) and a search, sorted.
function filtered(contacts, bookId, query) {
  return (contacts || []).filter(function(c) {
    return (!bookId || c.bookId === bookId) && matches(c, query)
  }).sort(compare)
}

function keyOf(c) { return c ? (c.href || c.uid || "") : "" }

function indexOfKey(list, key) {
  if (!key) return -1
  for (var i = 0; i < list.length; i++) if (keyOf(list[i]) === key) return i
  return -1
}

function addressLines(a) {
  if (!a) return []
  var cityLine = [trim(a.city), [trim(a.region), trim(a.code)].filter(function(x) { return x }).join(" ")]
    .filter(function(x) { return x }).join(", ")
  return trim(a.street).split("\n").map(trim).concat([cityLine, trim(a.country)]).filter(function(x) { return x })
}

// { year (0 = unknown), month 1-12, day } or null.
function birthdayParts(b) {
  var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(trim(b))
  if (m) return { year: +m[1], month: +m[2], day: +m[3] }
  m = /^--(\d{2})-(\d{2})$/.exec(trim(b))
  if (m) return { year: 0, month: +m[1], day: +m[2] }
  return null
}

// Editor text -> stored birthday. Accepts yyyy-MM-dd, MM/dd/yyyy, MM-dd and
// MM/dd (no year). Returns { value } or { error }.
function parseBirthday(text) {
  var t = trim(text)
  if (!t) return { value: "" }
  var y = 0, mo, d, m
  if ((m = /^(\d{4})-(\d{1,2})-(\d{1,2})$/.exec(t))) { y = +m[1]; mo = +m[2]; d = +m[3] }
  else if ((m = /^(\d{1,2})[\/.](\d{1,2})[\/.](\d{4})$/.exec(t))) { mo = +m[1]; d = +m[2]; y = +m[3] }
  else if ((m = /^-{0,2}(\d{1,2})[\/-](\d{1,2})$/.exec(t))) { mo = +m[1]; d = +m[2] }
  else return { error: "Birthday: use yyyy-mm-dd, or mm-dd without a year" }
  var maxDay = [31, (y === 0 || (y % 4 === 0 && (y % 100 !== 0 || y % 400 === 0))) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][mo - 1]
  if (!maxDay || d < 1 || d > maxDay) return { error: "Birthday: that date does not exist" }
  var p2 = function(n) { return (n < 10 ? "0" : "") + n }
  return { value: y ? y + "-" + p2(mo) + "-" + p2(d) : "--" + p2(mo) + "-" + p2(d) }
}

function birthdayText(b) {
  var p = birthdayParts(b)
  if (!p) return ""
  var p2 = function(n) { return (n < 10 ? "0" : "") + n }
  return p.year ? p.year + "-" + p2(p.month) + "-" + p2(p.day) : p2(p.month) + "-" + p2(p.day)
}

function _rows(list, fields) {
  return (list || []).map(function(r) {
    var o = {}
    for (var i = 0; i < fields.length; i++) o[fields[i]] = r[fields[i]] === undefined ? "" : String(r[fields[i]])
    return o
  })
}

// Contact -> editor form (plain strings and row arrays).
function formFor(c) {
  c = c || {}
  return {
    given: trim(c.given), family: trim(c.family), org: trim(c.org), title: trim(c.title),
    // A card with only FN (no N) still has a name to edit.
    fnOnly: !trim(c.given) && !trim(c.family) && !trim(c.prefix) && !trim(c.suffix) && !trim(c.additional) ? trim(c.fn) : "",
    emails: _rows(c.emails, ["type", "value"]),
    phones: _rows(c.phones, ["type", "value"]),
    addresses: _rows(c.addresses, ["type", "street", "city", "region", "code", "country"]),
    urls: (c.urls || []).map(function(u) { return { value: String(u) } }),
    birthday: birthdayText(c.birthday),
    notes: c.notes ? String(c.notes) : "",
    bookId: c.bookId || ""
  }
}

// Form + the record being edited (or null) -> { contact } or { error }.
// Fields the editor does not show (prefix, suffix, additional, photo,
// href, etag, uid) are carried over from the original.
function buildContact(form, original) {
  var out = {}
  if (original) for (var k in original) out[k] = original[k]
  var given = trim(form.given), family = trim(form.family)
  if (!given && !family && trim(form.fnOnly)) {
    // Split a lone FN into given/family so N is written properly.
    var words = trim(form.fnOnly).split(/\s+/)
    family = words.length > 1 ? words.pop() : ""
    given = words.join(" ")
  }
  out.given = given
  out.family = family
  out.org = trim(form.org)
  out.title = trim(form.title)
  out.emails = (form.emails || []).filter(function(e) { return trim(e.value) })
    .map(function(e) { return { type: EMAIL_TYPES.indexOf(e.type) !== -1 ? e.type : "other", value: trim(e.value) } })
  out.phones = (form.phones || []).filter(function(p) { return trim(p.value) })
    .map(function(p) { return { type: PHONE_TYPES.indexOf(p.type) !== -1 ? p.type : "other", value: trim(p.value) } })
  out.addresses = (form.addresses || []).filter(function(a) {
    return trim(a.street) || trim(a.city) || trim(a.region) || trim(a.code) || trim(a.country)
  }).map(function(a) {
    return { type: ADDRESS_TYPES.indexOf(a.type) !== -1 ? a.type : "other", street: trim(a.street), city: trim(a.city),
             region: trim(a.region), code: trim(a.code), country: trim(a.country) }
  })
  out.urls = (form.urls || []).map(function(u) { return trim(u.value) }).filter(function(u) { return u })
  var bd = parseBirthday(form.birthday)
  if (bd.error) return { error: bd.error }
  out.birthday = bd.value
  out.notes = String(form.notes || "").replace(/\s+$/, "")
  out.bookId = form.bookId || out.bookId || ""
  out.fn = displayName(out)
  if (!out.fn) return { error: "Give the contact a name, a company or an email address" }
  if (!out.bookId) return { error: "Pick an address book" }
  for (var i = 0; i < out.emails.length; i++)
    if (!/^[^@\s]+@[^@\s]+$/.test(out.emails[i].value)) return { error: "\"" + out.emails[i].value + "\" is not an email address" }
  return { contact: out }
}

function telUrl(v) { return "tel:" + String(v || "").replace(/[^\d+*#,;]/g, "") }
function mailUrl(v) { return "mailto:" + trim(v) }
function webUrl(v) { var t = trim(v); return /^[a-z][a-z0-9+.-]*:/i.test(t) ? t : "https://" + t }
function mapUrl(a) { return "https://www.openstreetmap.org/search?query=" + encodeURIComponent(addressLines(a).join(", ")) }

if (typeof module !== "undefined") {
  module.exports = {
    EMAIL_TYPES: EMAIL_TYPES, PHONE_TYPES: PHONE_TYPES, ADDRESS_TYPES: ADDRESS_TYPES,
    typeLabel: typeLabel, displayName: displayName, sortKey: sortKey, compare: compare, sectionOf: sectionOf,
    initials: initials, matches: matches, filtered: filtered, keyOf: keyOf, indexOfKey: indexOfKey,
    addressLines: addressLines, birthdayParts: birthdayParts, parseBirthday: parseBirthday, birthdayText: birthdayText,
    formFor: formFor, buildContact: buildContact, telUrl: telUrl, mailUrl: mailUrl, webUrl: webUrl, mapUrl: mapUrl
  }
}
