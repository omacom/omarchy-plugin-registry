// omarchy-site theme runtime, ported from omacom/omarchy-site src/lib/theme.ts.
// The 22 site themes (same ids, same order, same light flags); the picker
// reads SITE_THEMES from the page. No framework, no view transitions —
// applyTheme stamps, persists, and notifies; the header/footer listen for
// THEME_EVENT to re-read their colors.
export const SITE_THEMES = [
  { id: "catppuccin", name: "Catppuccin" },
  { id: "catppuccin-latte", name: "Catppuccin Latte", light: true },
  { id: "ethereal", name: "Ethereal" },
  { id: "everforest", name: "Everforest" },
  { id: "flexoki-light", name: "Flexoki Light", light: true },
  { id: "gruvbox", name: "Gruvbox" },
  { id: "hackerman", name: "Hackerman" },
  { id: "kanagawa", name: "Kanagawa" },
  { id: "last-horizon", name: "Last Horizon" },
  { id: "lumon", name: "Lumon" },
  { id: "lupine", name: "Lupine", light: true },
  { id: "matte-black", name: "Matte Black" },
  { id: "miasma", name: "Miasma" },
  { id: "nord", name: "Nord" },
  { id: "osaka-jade", name: "Osaka Jade" },
  { id: "retro-82", name: "Retro 82" },
  { id: "ristretto", name: "Ristretto" },
  { id: "rose-pine", name: "Rosé Pine", light: true },
  { id: "solitude", name: "Solitude" },
  { id: "tokyo-night", name: "Tokyo Night" },
  { id: "vantablack", name: "Vantablack" },
  { id: "white", name: "White", light: true },
]

export const DEFAULT_THEME = "tokyo-night"
export const THEME_KEY = "omarchy-site-theme"
/** Fired on window after a theme lands, for painters to re-read. */
export const THEME_EVENT = "omarchy-theme"
/** Ask the mounted theme picker to open. */
export const OPEN_PICKER_EVENT = "omarchy-open-picker"
/** Set once the user has seen the picker or dismissed the hint. */
export const HINT_KEY = "omarchy-theme-hint-seen"

const IDS = SITE_THEMES.map((t) => t.id)
const LIGHT = SITE_THEMES.filter((t) => t.light).map((t) => t.id)
const DARK = SITE_THEMES.filter((t) => !t.light).map((t) => t.id)

export function readTheme() {
  try {
    const stored = localStorage.getItem(THEME_KEY)
    if (IDS.includes(stored)) return stored
  } catch {
    /* storage unavailable */
  }
  return DEFAULT_THEME
}

// Stamp the saved palette (or a system-matching random one) before first
// paint. Runs inline in <head>, so no imports, no exports used here —
// mirrored by the inline script in the layout.
export function themeInitScript() {
  return `(function(){try{var t=localStorage.getItem(${JSON.stringify(THEME_KEY)});var ok=${JSON.stringify(IDS)};var light=${JSON.stringify(LIGHT)};var dark=${JSON.stringify(DARK)};if(ok.indexOf(t)<0){var pool=window.matchMedia&&matchMedia('(prefers-color-scheme: light)').matches?light:dark;t=pool[Math.floor(Math.random()*pool.length)];localStorage.setItem(${JSON.stringify(THEME_KEY)},t)}document.documentElement.dataset.theme=t}catch(e){document.documentElement.dataset.theme=${JSON.stringify(DEFAULT_THEME)}}})()`
}

// The square-spiral glyph (public/brand/omarchy-logo.svg), same path the
// header mark inlines — the favicon is drawn from it so the two cannot drift.
const MARK_PATH =
  "m1200 1200h-480v-80h400v-1040h-479.996v160h-400v720h720v-720h-80v-80h159.996v880h-400v160h-640v-1200h1200zm-1120-80h480v-80h-400l.004-400h-80.004zm0-560h80.004v-400h400v-80h-480.004z"

/** Replace the favicon link to invalidate browsers that cache it by element. */
export function paintFavicon() {
  const brand = getComputedStyle(document.documentElement)
    .getPropertyValue("--color-brand")
    .trim()
  if (!brand) return
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 1200"><path fill="${brand}" fill-rule="evenodd" clip-rule="evenodd" d="${MARK_PATH}"/></svg>`
  const link = document.createElement("link")
  link.rel = "icon"
  link.type = "image/svg+xml"
  link.setAttribute("data-theme-icon", "")
  link.href = `data:image/svg+xml,${encodeURIComponent(svg)}`
  document
    .querySelectorAll('link[rel="icon"][data-theme-icon]')
    .forEach((old) => old.remove())
  document.head.appendChild(link)
}

/**
 * Applies a theme: stamps it, persists it, and disables transitions for the
 * swap so hundreds of colors don't tween independently. Listeners (the
 * footer's pixel field, the header bar) re-read on THEME_EVENT.
 */
export function applyTheme(id) {
  const root = document.documentElement
  root.classList.add("no-transitions")
  root.dataset.theme = id
  try {
    localStorage.setItem(THEME_KEY, id)
  } catch {
    /* storage unavailable */
  }
  paintFavicon()
  window.dispatchEvent(new CustomEvent(THEME_EVENT, { detail: id }))
  requestAnimationFrame(() => {
    requestAnimationFrame(() => root.classList.remove("no-transitions"))
  })
}
