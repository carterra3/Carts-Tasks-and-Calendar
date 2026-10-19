// Theme-derived calendar colors.
//
// A calendar's color is stored as a *spec* string, not a resolved color:
//   "theme:blue"   -> whatever `blue` is in the active Omarchy theme
//   "#ff8800"      -> a fixed custom color that ignores theme changes
//
// Because theme specs are resolved at render time against the live
// colors.toml, every theme-colored calendar recolors itself the moment the
// system theme changes, with no migration or rewrite of the data file.
//
// Pure JS (no Qt) so it can be unit tested under node.

// Suggestion order: the theme's accent first, then the chromatic hues in a
// wheel-ish order, then their bright twins. Neutrals come last.
var ROLES = [
  "accent",
  "blue", "cyan", "green", "yellow", "orange", "red", "magenta",
  "bright_blue", "bright_cyan", "bright_green", "bright_yellow", "bright_red", "bright_magenta",
  "brown", "foreground", "muted"
]

var LABELS = {
  accent: "Accent", blue: "Blue", cyan: "Cyan", green: "Green", yellow: "Yellow",
  orange: "Orange", red: "Red", magenta: "Magenta", brown: "Brown",
  bright_blue: "Bright blue", bright_cyan: "Bright cyan", bright_green: "Bright green",
  bright_yellow: "Bright yellow", bright_red: "Bright red", bright_magenta: "Bright magenta",
  foreground: "Foreground", muted: "Muted"
}

// Older/hand-written themes may only carry the 16 ANSI slots, or may be
// missing a named hue. Each role falls back through these keys in order so a
// theme switch never leaves a calendar colorless.
var FALLBACKS = {
  accent: ["color4", "blue"],
  red: ["color1"], green: ["color2"], yellow: ["color3"], blue: ["color4"],
  magenta: ["color5"], cyan: ["color6"],
  orange: ["bright_red", "color9", "yellow", "color3"],
  brown: ["yellow", "color3"],
  bright_red: ["color9", "red", "color1"], bright_green: ["color10", "green", "color2"],
  bright_yellow: ["color11", "yellow", "color3"], bright_blue: ["color12", "blue", "color4"],
  bright_magenta: ["color13", "magenta", "color5"], bright_cyan: ["color14", "cyan", "color6"],
  foreground: ["color7"], muted: ["color8", "dark_foreground"]
}

function parseColorsToml(raw) {
  var out = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var m = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
    if (m) out[m[1]] = m[2].toLowerCase()
  }
  return out
}

function roleHex(palette, role) {
  if (!palette) return ""
  if (palette[role]) return palette[role]
  var chain = FALLBACKS[role] || []
  for (var i = 0; i < chain.length; i++) if (palette[chain[i]]) return palette[chain[i]]
  return ""
}

function isHex(value) {
  return /^#[0-9A-Fa-f]{6}$/.test(String(value || ""))
}

function normalizeHex(value) {
  var text = String(value || "").replace(/^\s+|\s+$/g, "")
  if (text.charAt(0) !== "#") text = "#" + text
  if (/^#[0-9A-Fa-f]{3}$/.test(text))
    text = "#" + text.charAt(1) + text.charAt(1) + text.charAt(2) + text.charAt(2) + text.charAt(3) + text.charAt(3)
  return isHex(text) ? text.toLowerCase() : ""
}

function isThemeSpec(spec) {
  return String(spec || "").indexOf("theme:") === 0
}

function specRole(spec) {
  return isThemeSpec(spec) ? String(spec).substr(6) : ""
}

// Resolve a stored spec to "#rrggbb" against the live palette.
function resolve(palette, spec, fallback) {
  var s = String(spec || "")
  if (isThemeSpec(s)) {
    var hex = roleHex(palette, specRole(s))
    return hex || fallback || "#888888"
  }
  return normalizeHex(s) || fallback || "#888888"
}

function label(spec) {
  if (isThemeSpec(spec)) {
    var role = specRole(spec)
    return "Theme " + (LABELS[role] || role).toLowerCase()
  }
  return "Custom " + String(spec || "")
}

// Swatches the current theme can offer, de-duplicated by resolved color so a
// theme whose bright_* equal its normal hues does not show twin swatches.
function suggestions(palette) {
  var out = []
  var seen = {}
  for (var i = 0; i < ROLES.length; i++) {
    var role = ROLES[i]
    var hex = roleHex(palette, role)
    if (!hex || seen[hex]) continue
    seen[hex] = true
    out.push({ spec: "theme:" + role, role: role, label: LABELS[role] || role, hex: hex })
  }
  return out
}

// The first theme color not already used by another calendar (compared by
// resolved color, so "theme:blue" and "theme:accent" that happen to match
// count as the same). Wraps to the first suggestion when all are taken.
function nextSuggestion(palette, usedSpecs) {
  var options = suggestions(palette)
  if (options.length === 0) return "theme:accent"
  var used = {}
  for (var i = 0; i < (usedSpecs || []).length; i++) used[resolve(palette, usedSpecs[i], "")] = true
  for (var j = 0; j < options.length; j++) if (!used[options[j].hex]) return options[j].spec
  return options[(usedSpecs || []).length % options.length].spec
}

if (typeof module !== "undefined") {
  module.exports = {
    ROLES: ROLES, parseColorsToml: parseColorsToml, roleHex: roleHex, isHex: isHex,
    normalizeHex: normalizeHex, isThemeSpec: isThemeSpec, specRole: specRole,
    resolve: resolve, label: label, suggestions: suggestions, nextSuggestion: nextSuggestion
  }
}
