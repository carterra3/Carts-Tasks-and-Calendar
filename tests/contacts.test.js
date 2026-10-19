const assert = require("assert")
const C = require("../Contacts.js")

const mary = { fn: "Mary Garcia", given: "Mary", family: "Garcia", org: "Acme", emails: [{ type: "home", value: "m@example.com" }],
  phones: [{ type: "cell", value: "(555) 010-0100" }], addresses: [{ type: "home", street: "1 Main St\nApt 2", city: "Springfield", region: "OR", code: "97477", country: "USA" }],
  urls: ["example.com"], birthday: "1990-03-14", notes: "likes tea", href: "https://d/ab/1.vcf", bookId: "ab1" }
const orgOnly = { fn: "", org: "Zed Plumbing", emails: [], phones: [], bookId: "ab2", href: "https://d/ab2/2.vcf" }
const emailOnly = { fn: "", emails: [{ type: "other", value: "x@y.z" }], bookId: "ab1", href: "h3" }
const accent = { fn: "Émile Zola", given: "Émile", family: "Zola", bookId: "ab1", href: "h4" }
const digit = { fn: "123 Taxi", org: "123 Taxi", bookId: "ab1", href: "h5" }

// names, sections, initials
assert.strictEqual(C.displayName(mary), "Mary Garcia")
assert.strictEqual(C.displayName(orgOnly), "Zed Plumbing")
assert.strictEqual(C.displayName(emailOnly), "x@y.z")
assert.strictEqual(C.sectionOf(mary), "G")              // family name first
assert.strictEqual(C.sectionOf({ given: "Émile" }), "E")
assert.strictEqual(C.sectionOf(digit), "#")
assert.strictEqual(C.initials(mary), "MG")
assert.strictEqual(C.initials(orgOnly), "ZP")
assert.strictEqual(C.initials({}), "?")

// search
assert.ok(C.matches(mary, "mary acme"))
assert.ok(C.matches(mary, "GAR"))
assert.ok(C.matches(mary, "5550100100"))
assert.ok(C.matches(mary, "555-010"))
assert.ok(C.matches(mary, "springfield"))
assert.ok(!C.matches(mary, "mary zed"))
assert.ok(C.matches(mary, "   "))

// filter + sort
const all = [orgOnly, mary, emailOnly, accent, digit]
assert.deepStrictEqual(C.filtered(all, "", "").map(C.displayName), ["123 Taxi", "Mary Garcia", "x@y.z", "Zed Plumbing", "Émile Zola"])
assert.deepStrictEqual(C.filtered(all, "ab2", "").map(C.displayName), ["Zed Plumbing"])
assert.deepStrictEqual(C.filtered(all, "ab1", "zola").map(C.displayName), ["Émile Zola"])
assert.strictEqual(C.indexOfKey(all, "h3"), 2)
assert.strictEqual(C.indexOfKey(all, ""), -1)

// addresses
assert.deepStrictEqual(C.addressLines(mary.addresses[0]), ["1 Main St", "Apt 2", "Springfield, OR 97477", "USA"])
assert.deepStrictEqual(C.addressLines({ city: "Paris", country: "France" }), ["Paris", "France"])

// birthdays
assert.deepStrictEqual(C.parseBirthday("1990-3-14"), { value: "1990-03-14" })
assert.deepStrictEqual(C.parseBirthday("03/14/1990"), { value: "1990-03-14" })
assert.deepStrictEqual(C.parseBirthday("02-29"), { value: "--02-29" })
assert.deepStrictEqual(C.parseBirthday(""), { value: "" })
assert.ok(C.parseBirthday("1990-02-30").error)
assert.ok(C.parseBirthday("2001-02-29").error)
assert.ok(C.parseBirthday("soon").error)
assert.deepStrictEqual(C.birthdayParts("--12-25"), { year: 0, month: 12, day: 25 })
assert.strictEqual(C.birthdayText("--12-25"), "12-25")

// form round trip keeps hidden fields
const withHidden = Object.assign({}, mary, { prefix: "Dr", photo: "data:image/png;base64,AA", etag: "\"e\"", uid: "U1" })
let f = C.formFor(withHidden)
assert.strictEqual(f.birthday, "1990-03-14")
assert.strictEqual(f.emails[0].value, "m@example.com")
f.phones.push({ type: "work", value: "  " })            // empty rows are dropped
f.emails.push({ type: "bogus", value: "w@example.com" })
let r = C.buildContact(f, withHidden)
assert.ok(r.contact, r.error)
assert.strictEqual(r.contact.phones.length, 1)
assert.deepStrictEqual(r.contact.emails[1], { type: "other", value: "w@example.com" })
assert.strictEqual(r.contact.prefix, "Dr")
assert.strictEqual(r.contact.photo, withHidden.photo)
assert.strictEqual(r.contact.etag, "\"e\"")
assert.strictEqual(r.contact.fn, "Dr Mary Garcia")

// FN-only card gets split into given/family
r = C.buildContact(C.formFor({ fn: "Ann Marie Lee", bookId: "ab1" }), { fn: "Ann Marie Lee", bookId: "ab1" })
assert.strictEqual(r.contact.given, "Ann Marie")
assert.strictEqual(r.contact.family, "Lee")

// validation
assert.ok(C.buildContact({ given: "", family: "", bookId: "ab1" }, null).error)
assert.ok(C.buildContact({ given: "A", bookId: "" }, null).error)
assert.ok(/not an email/.test(C.buildContact({ given: "A", bookId: "ab1", emails: [{ type: "home", value: "nope" }] }, null).error))
assert.ok(/Birthday/.test(C.buildContact({ given: "A", bookId: "ab1", birthday: "13/40" }, null).error))

// links
assert.strictEqual(C.telUrl("(555) 010-0100"), "tel:5550100100")
assert.strictEqual(C.telUrl("+1 555 0100"), "tel:+15550100")
assert.strictEqual(C.webUrl("example.com"), "https://example.com")
assert.strictEqual(C.webUrl("http://x.y"), "http://x.y")

console.log("contacts tests passed")
