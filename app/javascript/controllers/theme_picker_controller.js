// The theme deck, ported from omarchy-site's ThemePicker: the same 22 site
// themes as slanted preview cards (same 2.5% parallelogram lean), stepped
// with ←/→/Enter/Escape, opened by the header palette button, the "T" key,
// or an OPEN_PICKER_EVENT. Previews are hotlinked from omarchy.org so this
// app ships no image payload of its own.
import { Controller } from "@hotwired/stimulus"
import {
  SITE_THEMES,
  OPEN_PICKER_EVENT,
  HINT_KEY,
  applyTheme,
  readTheme,
} from "lib/omarchy-theme"

const previewSrc = (id) =>
  `https://omarchy.org/assets/images/theme-previews/${id}.webp`

/** Omarchy's card slant: a 2.5% lean, top edge shifted right of the bottom. */
const PARALLELOGRAM = "polygon(2.5% 0%, 100% 0%, 97.5% 100%, 0% 100%)"

/** Inset in the same coordinate box to keep the slanted border edges parallel. */
const parallelogramInset = (b) =>
  `polygon(calc(2.5% + ${b}) ${b}, calc(100% - ${b}) ${b}, calc(97.5% - ${b}) calc(100% - ${b}), ${b} calc(100% - ${b}))`

/** True while the keystroke belongs to a field the reader is typing into. */
const isTyping = (target) => {
  const el = target
  if (!el?.tagName) return false
  return (
    el.tagName === "INPUT" ||
    el.tagName === "TEXTAREA" ||
    el.tagName === "SELECT" ||
    el.isContentEditable
  )
}

export default class extends Controller {
  static targets = ["deck", "name", "hint"]

  connect() {
    this.open = false
    this.index = 0
    this.restoreFocus = null
    this.warmed = new Set()
    this.onGlobalKey = (e) => this.globalKey(e)
    this.onOpenRequest = () => this.openPicker()
    window.addEventListener("keydown", this.onGlobalKey)
    window.addEventListener(OPEN_PICKER_EVENT, this.onOpenRequest)
    // Some WebViews lack requestIdleCallback; retain a timeout fallback.
    const idle =
      window.requestIdleCallback ?? ((cb) => window.setTimeout(cb, 1500))
    idle(() => {
      const at = SITE_THEMES.findIndex((t) => t.id === readTheme())
      this.warmAround(at >= 0 ? at : 0)
    })
    let seen = true
    try {
      seen = localStorage.getItem(HINT_KEY) === "true"
    } catch {
      /* storage unavailable: show nothing rather than nag every visit */
    }
    if (!seen) window.setTimeout(() => this.showHint(), 1600)
  }

  disconnect() {
    window.removeEventListener("keydown", this.onGlobalKey)
    window.removeEventListener(OPEN_PICKER_EVENT, this.onOpenRequest)
  }

  markHintSeen() {
    this.hideHint()
    try {
      localStorage.setItem(HINT_KEY, "true")
    } catch {
      /* storage unavailable */
    }
  }

  showHint() {
    if (this.open || !this.hasHintTarget) return
    this.hintTarget.hidden = false
  }

  hideHint() {
    if (this.hasHintTarget) this.hintTarget.hidden = true
  }

  openHintPicker(event) {
    event?.preventDefault()
    this.markHintSeen()
    this.openPicker()
  }

  dismissHint(event) {
    event?.preventDefault()
    this.markHintSeen()
  }

  // The entry point is T. A bare T only: leave Cmd/Ctrl/Alt combinations to
  // the browser, and never fire while someone is typing, or searching the
  // plugin directory would open the picker on the first letter.
  globalKey(event) {
    const plainT =
      event.key.toLowerCase() === "t" &&
      !event.metaKey &&
      !event.ctrlKey &&
      !event.altKey &&
      !isTyping(event.target)
    if (!plainT) return
    event.preventDefault()
    if (this.open) this.close()
    else this.openPicker()
  }

  openPicker() {
    const current = readTheme()
    const at = SITE_THEMES.findIndex((t) => t.id === current)
    this.index = at >= 0 ? at : 0
    this.restoreFocus = document.activeElement
    this.open = true
    this.markHintSeen()
    this.element.hidden = false
    document.documentElement.dataset.navMenu = "open"
    this.paint()
    this.dialog().focus()
  }

  close(restore = true) {
    this.open = false
    this.element.hidden = true
    delete document.documentElement.dataset.navMenu
    if (restore && this.restoreFocus?.focus) {
      this.restoreFocus.focus({ preventScroll: true })
    }
  }

  dialog() {
    return this.element.querySelector('[role="dialog"]')
  }

  pickerKey(event) {
    if (event.key === "ArrowLeft" || event.key === "Left") {
      event.preventDefault()
      this.step(-1)
    } else if (event.key === "ArrowRight" || event.key === "Right") {
      event.preventDefault()
      this.step(1)
    } else if (event.key === "Enter") {
      event.preventDefault()
      this.choose()
    } else if (event.key === "Escape") {
      event.preventDefault()
      this.close()
    }
  }

  step(delta) {
    this.index =
      (this.index + delta + SITE_THEMES.length) % SITE_THEMES.length
    this.paint()
  }

  previous() {
    this.step(-1)
  }

  next() {
    this.step(1)
  }

  go(event) {
    const at = Number(event.currentTarget.dataset.index)
    if (Number.isInteger(at)) {
      this.index = at
      this.paint()
    }
  }

  pick(event) {
    const at = Number(event.currentTarget.dataset.index)
    if (Number.isInteger(at)) {
      if (at === this.index) this.choose()
      else {
        this.index = at
        this.paint()
      }
    }
  }

  choose() {
    const next = SITE_THEMES[this.index]
    this.close(false)
    if (next.id !== readTheme()) applyTheme(next.id)
    if (this.restoreFocus?.focus) {
      this.restoreFocus.focus({ preventScroll: true })
    }
  }

  // Decode only the visible previews and their neighbors.
  warmAround(at) {
    for (let d = -2; d <= 2; d++) {
      const theme =
        SITE_THEMES[(at + d + SITE_THEMES.length) % SITE_THEMES.length]
      if (this.warmed.has(theme.id)) continue
      this.warmed.add(theme.id)
      const img = new Image()
      img.fetchPriority = "low"
      img.decoding = "async"
      img.src = previewSrc(theme.id)
      img.decode?.().catch(() => {})
    }
  }

  paint() {
    this.warmAround(this.index)
    const half = SITE_THEMES.length / 2
    this.deckTarget.innerHTML = ""
    SITE_THEMES.forEach((theme, i) => {
      const raw = i - this.index
      const offset =
        raw > half ? raw - SITE_THEMES.length : raw < -half ? raw + SITE_THEMES.length : raw
      const depth = Math.abs(offset)
      if (depth > 2) return
      // Neighbours tuck in close behind the front card and stay solid, just
      // darkened, the way the OS stacks its deck.
      const shift = offset === 0 ? 0 : Math.sign(offset) * (6 + depth * 12)
      const wrap = document.createElement("div")
      wrap.className = "omarchy-theme-card"
      wrap.setAttribute("aria-hidden", offset !== 0 ? "true" : "false")
      wrap.style.transform = `translateX(${shift}%) scale(${depth === 0 ? 1 : 0.88})`
      wrap.style.zIndex = 10 - depth
      const button = document.createElement("button")
      button.type = "button"
      button.tabIndex = -1
      button.dataset.index = i
      button.setAttribute(
        "aria-label",
        offset === 0 ? `Use ${theme.name}` : `Show ${theme.name}`
      )
      button.className = "omarchy-theme-card__button"
      button.addEventListener("click", (e) => this.pick(e))
      const frame = document.createElement("div")
      frame.className =
        "omarchy-theme-card__frame " +
        (depth === 0
          ? "omarchy-theme-card__frame--front"
          : "omarchy-theme-card__frame--back")
      frame.style.clipPath = PARALLELOGRAM
      const inner = document.createElement("div")
      inner.className = "omarchy-theme-card__inner"
      inner.style.clipPath = parallelogramInset(depth === 0 ? "3px" : "1px")
      const img = document.createElement("img")
      img.src = previewSrc(theme.id)
      img.alt = `${theme.name} theme preview`
      img.width = 1800
      img.height = 1012
      img.draggable = false
      img.className = "omarchy-theme-card__img"
      if (depth !== 0) img.style.filter = "brightness(0.55)"
      img.addEventListener("error", () => {
        if (img.dataset.retried) return
        img.dataset.retried = ""
        window.setTimeout(() => {
          img.src = `${previewSrc(theme.id)}?retry`
        }, 1000)
      })
      inner.appendChild(img)
      frame.appendChild(inner)
      button.appendChild(frame)
      wrap.appendChild(button)
      this.deckTarget.appendChild(wrap)
    })
    const theme = SITE_THEMES[this.index]
    this.nameTarget.textContent = theme.name
    this.nameTarget.dataset.theme = theme.id
    this.nameTarget.classList.toggle("omarchy-theme-name--light", !!theme.light)
  }
}
