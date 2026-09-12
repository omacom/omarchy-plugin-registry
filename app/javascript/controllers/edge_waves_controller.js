import { Controller } from "@hotwired/stimulus"

const CELL_PITCH = 18
const CELL_SIZE = 7
const FIRST_WAVE_DELAY_MS = 320
const WAVE_DURATION_MS = 2600
const REVEAL_DURATION_MS = 500
const POINTER_WAVE_DURATION_MS = 900
const POINTER_WAVE_RADIUS = 240
const POINTER_SAMPLE_DISTANCE = 24
const POINTER_SAMPLE_INTERVAL_MS = 70
const MAX_POINTER_WAKES = 6
const INNER_GAP = 12
const MIN_GUTTER = 20
const MAX_DPR = 1
const PAUSE_KEY = "registry:edge-waves-paused"

const clamp = (value, minimum = 0, maximum = 1) => Math.min(maximum, Math.max(minimum, value))
const smooth = (value) => {
  const amount = clamp(value)
  return amount * amount * (3 - 2 * amount)
}

// Stable noise keeps the field pattern from changing on resize or theme swap.
const noise = (column, row, side) => {
  let value = Math.imul(column + 1, 374761393) ^ Math.imul(row + 1, 668265263) ^ Math.imul(side + 1, 1442695041)
  value = Math.imul(value ^ (value >>> 13), 1274126177)
  return ((value ^ (value >>> 16)) >>> 0) / 4294967295
}

export default class extends Controller {
  static targets = ["canvas", "layer", "toggle", "toggleLabel"]
  static values = { interval: { type: Number, default: 6000 } }

  connect() {
    this.canvasContext = this.canvasTarget.getContext("2d", { alpha: true })
    if (!this.canvasContext) return

    this.hero = document.querySelector(".hero")
    this.rail = this.hero || document.querySelector("body > .rail")
    this.motionQuery = window.matchMedia("(prefers-reduced-motion: reduce)")
    this.paused = this.storedPause()
    this.restoredQuiet = this.element.dataset.edgeWavesState === "quiet"
    this.fieldRevealed = this.restoredQuiet || this.paused || this.motionQuery.matches
    this.pointerWakes = []
    this.lastPointerSample = null
    this.animationMode = null
    this.ready = false
    this.onResize = () => this.layout()
    this.onScroll = () => {
      if (this.scrollFrame) return
      this.scrollFrame = requestAnimationFrame(() => {
        this.scrollFrame = null
        this.updateZones()
        if (!this.visibleCells.length) {
          this.stop()
          this.clear()
          this.setState("quiet")
          this.syncToggle()
          return
        }
        if (this.paused) this.pause()
        else if (this.motionQuery.matches) this.reduceMotion()
        else if (!this.frame && !this.timer) this.scheduleWave(0)
        else if (!this.frame && this.fieldRevealed) this.drawStatic()
        this.syncToggle()
      })
    }
    this.onMotionChange = () => this.syncMotionPreference()
    this.onPointerMove = (event) => this.pointerMove(event)
    this.onVisibilityChange = () => {
      if (document.hidden) {
        this.stop()
        if (this.paused) this.clear()
        else this.drawStatic()
        this.setState("quiet")
      } else if (this.paused) {
        this.pause()
      } else if (this.motionQuery.matches) {
        this.reduceMotion()
      } else {
        this.scheduleWave(0)
      }
    }
    this.beforeCache = () => {
      this.stop()
      if (this.paused) {
        this.clear()
        this.setState("paused")
      } else {
        this.drawStatic()
        this.setState("quiet")
      }
    }
    this.onThemeChange = () => {
      cancelAnimationFrame(this.themeFrame)
      this.themeFrame = requestAnimationFrame(() => {
        this.themeFrame = requestAnimationFrame(() => {
          this.themeFrame = null
          this.readInk()
          if (!this.frame && this.fieldRevealed) this.drawStatic()
        })
      })
    }

    window.addEventListener("resize", this.onResize)
    window.addEventListener("scroll", this.onScroll, { passive: true })
    this.rail?.addEventListener("pointermove", this.onPointerMove, { passive: true })
    document.addEventListener("visibilitychange", this.onVisibilityChange)
    document.addEventListener("registry:theme-change", this.onThemeChange)
    document.addEventListener("turbo:before-cache", this.beforeCache)
    this.motionQuery.addEventListener("change", this.onMotionChange)
    this.themeObserver = new MutationObserver(this.onThemeChange)
    this.themeObserver.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-theme", "style"],
    })
    this.resizeObserver = new ResizeObserver(this.onResize)
    if (this.rail) this.resizeObserver.observe(this.rail)

    this.layout()
    this.ready = true
    if (!this.visibleCells.length) {
      this.stop()
      this.clear()
      this.setState("quiet")
      this.syncToggle()
    } else if (this.paused) this.pause()
    else if (this.motionQuery.matches) this.reduceMotion()
    else this.scheduleWave(this.restoredQuiet ? this.intervalValue : FIRST_WAVE_DELAY_MS)
  }

  disconnect() {
    this.stop()
    cancelAnimationFrame(this.scrollFrame)
    cancelAnimationFrame(this.themeFrame)
    this.scrollFrame = null
    this.themeFrame = null
    window.removeEventListener("resize", this.onResize)
    window.removeEventListener("scroll", this.onScroll)
    this.rail?.removeEventListener("pointermove", this.onPointerMove)
    document.removeEventListener("visibilitychange", this.onVisibilityChange)
    document.removeEventListener("registry:theme-change", this.onThemeChange)
    document.removeEventListener("turbo:before-cache", this.beforeCache)
    this.motionQuery?.removeEventListener("change", this.onMotionChange)
    this.resizeObserver?.disconnect()
    this.themeObserver?.disconnect()
  }

  layout() {
    if (!this.canvasContext || !this.rail) return
    const width = document.documentElement.clientWidth
    const height = window.innerHeight
    this.width = width
    this.height = height

    const dpr = Math.min(window.devicePixelRatio || 1, MAX_DPR)
    const pixelWidth = Math.round(width * dpr)
    const pixelHeight = Math.round(height * dpr)
    if (this.canvasTarget.width !== pixelWidth || this.canvasTarget.height !== pixelHeight) {
      this.canvasTarget.width = pixelWidth
      this.canvasTarget.height = pixelHeight
    }
    this.canvasContext.setTransform(dpr, 0, 0, dpr, 0, 0)
    const railBounds = this.rail.getBoundingClientRect()
    this.leftEdge = railBounds.left - INNER_GAP
    this.rightEdge = railBounds.right + INNER_GAP
    this.readInk()
    this.buildCells()
    this.updateZones()
    this.syncToggle()

    if (!this.visibleCells.length) {
      this.stop()
      this.clear()
      this.setState("quiet")
      this.syncToggle()
    } else if (this.ready && this.paused) {
      this.pause()
    } else if (this.ready && this.motionQuery.matches) {
      this.reduceMotion()
    } else {
      if (!this.frame) {
        if (this.fieldRevealed) this.drawStatic()
        else this.clear()
      }
      if (this.ready && !this.frame && !this.timer && !document.hidden) this.scheduleWave(0)
    }
  }

  readInk() {
    this.ink = getComputedStyle(this.canvasTarget).color
  }

  buildCells() {
    this.cells = []

    const columns = Math.ceil((this.width - 20) / CELL_PITCH)
    const rows = Math.ceil(this.height / CELL_PITCH)
    const halfWidth = this.width / 2
    const leftGutter = Math.max(0, this.leftEdge)
    const rightGutter = Math.max(0, this.width - this.rightEdge)
    const gutterDepth = Math.max(MIN_GUTTER, Math.min(leftGutter, rightGutter))

    for (let column = 0; column < columns; column += 1) {
      const x = 10 + column * CELL_PITCH
      const side = x < halfWidth ? 0 : 1
      const sideColumn = side === 0 ? column : columns - column - 1
      const distanceFromEdge = side === 0 ? x : this.width - x
      const baseDepth = distanceFromEdge <= gutterDepth
        ? (distanceFromEdge / gutterDepth) * 0.55
        : 0.55 + ((distanceFromEdge - gutterDepth) / Math.max(1, halfWidth - gutterDepth)) * 0.45

      for (let row = 0; row < rows; row += 1) {
        const strength = noise(sideColumn, row, side)
        if (strength < 0.48) continue
        this.cells.push({
          x,
          y: row * CELL_PITCH + (column % 2) * 2,
          depth: clamp(baseDepth + Math.sin(row * 0.72 + side * 1.3) * 0.035),
          strength,
          resting: strength > 0.79,
          size: strength > 0.9 ? CELL_SIZE + 2 : CELL_SIZE,
        })
      }
    }
  }

  updateZones() {
    const bounds = (selector) => document.querySelector(selector)?.getBoundingClientRect()
    const hero = bounds(".hero")
    const contentBounds = bounds(".site-bar")
    const areas = []
    this.heroTop = Math.max(0, hero?.top ?? 0)
    this.heroBottom = Math.min(this.height, hero?.bottom ?? 0)
    this.contentLeft = contentBounds?.left ?? this.leftEdge
    this.contentRight = contentBounds?.right ?? this.rightEdge

    const addArea = (left, right, top, bottom) => {
      const area = {
        left: Math.max(this.contentLeft, left + 3),
        right: Math.min(this.contentRight, right - 3),
        top: Math.max(this.heroTop, top + 3),
        bottom: Math.min(this.heroBottom, bottom - 3),
      }
      if (area.right - area.left >= CELL_SIZE && area.bottom - area.top >= CELL_SIZE) areas.push(area)
    }

    const bar = bounds(".site-bar")
    const heroCommand = bounds(".hero__command")
    const heroWordmark = bounds(".hero__wm")
    const heroCopy = bounds(".hero__copy")
    const heroLede = bounds(".hero__lede")
    const prompt = bounds(".promptline")
    const fetch = bounds(".fetch")
    if (bar && (heroCommand || fetch)) {
      addArea(this.contentLeft, this.contentRight, bar.bottom,
        Math.min(heroCommand?.top ?? this.heroBottom, fetch?.top ?? this.heroBottom))
    }
    if (heroCommand && heroWordmark && heroCopy) {
      addArea(heroCopy.left, heroCopy.right, heroCommand.bottom, heroWordmark.top)
    }
    if (heroWordmark && fetch) {
      addArea(heroWordmark.right, fetch.left, heroWordmark.top, Math.min(heroWordmark.bottom, fetch.bottom))
    }
    const copyElements = [heroCommand, heroWordmark, heroLede, prompt]
      .filter((area) => area?.width && area?.height)
    if (copyElements.length && fetch) {
      addArea(Math.max(...copyElements.map((area) => area.right)), fetch.left,
        Math.min(fetch.top, ...copyElements.map((area) => area.top)),
        Math.max(fetch.bottom, ...copyElements.map((area) => area.bottom)))
    }
    if (heroCopy && fetch && heroCopy.bottom < fetch.top) {
      addArea(this.contentLeft, this.contentRight, heroCopy.bottom, fetch.top)
    }
    if (hero && (heroCopy || fetch)) {
      addArea(this.contentLeft, this.contentRight,
        Math.max(heroCopy?.bottom || hero.top, fetch?.bottom || hero.top), hero.bottom)
    }

    this.zones = areas
    const visibleInHero = (cell) => {
      const centerX = cell.x + cell.size / 2
      if (cell.y < this.heroTop || cell.y + cell.size > this.heroBottom) return false
      if (centerX < this.leftEdge || centerX > this.rightEdge) return true
      return areas.some((area) => cell.x >= area.left && cell.x + cell.size <= area.right &&
        cell.y >= area.top && cell.y + cell.size <= area.bottom)
    }
    const contentExclusions = [heroCommand, heroWordmark, heroLede, prompt, fetch].filter(Boolean)
    const clearsContent = (cell) => !contentExclusions.some((area) =>
      cell.x < area.right && cell.x + cell.size > area.left && cell.y < area.bottom && cell.y + cell.size > area.top)
    this.visibleCells = (this.cells || []).filter((cell) => visibleInHero(cell) && clearsContent(cell))
  }

  toggle() {
    this.paused = !this.paused
    try {
      if (this.paused) sessionStorage.setItem(PAUSE_KEY, "true")
      else sessionStorage.removeItem(PAUSE_KEY)
    } catch {
    }

    if (this.paused) this.pause()
    else this.resume()
  }

  pause() {
    this.stop()
    this.fieldRevealed = false
    this.clear()
    this.setState("paused")
    this.syncToggle()
  }

  resume() {
    this.stop()
    if (this.motionQuery.matches) {
      this.reduceMotion()
      return
    }
    if (document.hidden || !this.visibleCells?.length) {
      this.scheduleWave(0)
      return
    }

    this.fieldRevealed = false
    this.animationMode = "reveal"
    this.revealStartedAt = null
    this.setState("animating")
    this.syncToggle()
    this.frame = requestAnimationFrame((time) => this.paintReveal(time))
  }

  paintReveal(time) {
    if (this.revealStartedAt === null) this.revealStartedAt = time
    const progress = clamp((time - this.revealStartedAt) / REVEAL_DURATION_MS)
    this.clear()
    this.drawRestingField(smooth(progress))

    if (progress >= 1) {
      this.frame = null
      this.fieldRevealed = true
      this.startWave()
    } else {
      this.frame = requestAnimationFrame((next) => this.paintReveal(next))
    }
  }

  reduceMotion() {
    this.stop()
    this.fieldRevealed = true
    this.drawStatic()
    this.setState("reduced")
    this.syncToggle()
  }

  syncMotionPreference() {
    if (this.paused) this.pause()
    else if (this.motionQuery.matches) this.reduceMotion()
    else this.scheduleWave(0)
  }

  scheduleWave(delay) {
    this.stop()
    if (this.fieldRevealed) this.drawStatic()
    else this.clear()
    if (this.paused || this.motionQuery.matches || document.hidden || !this.visibleCells?.length) {
      this.setState(!this.visibleCells?.length ? "quiet" : this.paused ? "paused" : this.motionQuery.matches ? "reduced" : "quiet")
      this.syncToggle()
      return
    }

    this.setState("quiet")
    this.syncToggle()
    if (delay > 0 && this.fieldRevealed) this.startSparkles()
    this.timer = window.setTimeout(() => {
      this.timer = null
      this.startWave()
    }, Math.max(0, delay))
  }

  startWave() {
    if (this.paused || this.motionQuery.matches || document.hidden || !this.visibleCells?.length) return
    cancelAnimationFrame(this.frame)
    this.stopSparkles()
    this.animationMode = "wave"
    this.setState("animating")
    this.startedAt = null
    this.frame = requestAnimationFrame((time) => this.paint(time))
  }

  stop() {
    cancelAnimationFrame(this.frame)
    window.clearTimeout(this.timer)
    this.stopSparkles()
    this.frame = null
    this.timer = null
    this.animationMode = null
    this.revealStartedAt = null
    this.pointerWakes = []
    this.lastPointerSample = null
  }

  completeWave() {
    cancelAnimationFrame(this.frame)
    this.frame = null
    this.animationMode = null
    this.fieldRevealed = true
    this.setState("quiet")
    if (!this.continuePointerWakes()) {
      this.drawStatic()
      this.startSparkles()
    }
    this.timer = window.setTimeout(() => {
      this.timer = null
      this.startWave()
    }, Math.max(0, this.intervalValue - WAVE_DURATION_MS))
  }

  paint(time) {
    if (this.startedAt === null) this.startedAt = time
    const progress = clamp((time - this.startedAt) / WAVE_DURATION_MS)
    const front = -0.08 + smooth(progress) * 1.16
    const intensity = Math.sin(Math.PI * progress)
    this.clear()

    for (const cell of this.visibleCells || []) {
      const crestDistance = (front - cell.depth) / 0.105
      const crest = Math.exp(-(crestDistance * crestDistance)) * intensity
      const fieldIntensity = this.fieldRevealed ? 1 : smooth((front - cell.depth) / 0.08)
      const resting = cell.resting ? (0.055 + cell.strength * 0.075) * fieldIntensity : 0
      const alpha = resting + crest * (0.13 + cell.strength * 0.23)
      this.drawCell(cell, alpha)
    }
    this.drawPointerWakes(time)

    if (progress >= 1) this.completeWave()
    else this.frame = requestAnimationFrame((next) => this.paint(next))
  }

  continuePointerWakes() {
    if (!this.pointerWakes?.length) return false
    this.stopSparkles()
    this.animationMode = "pointer"
    this.frame = requestAnimationFrame((time) => this.paintPointer(time))
    return true
  }

  pointerMove(event) {
    if (event.pointerType === "touch" || this.paused || this.motionQuery.matches || document.hidden ||
        !this.visibleCells?.length) return
    const now = performance.now()
    const previous = this.lastPointerSample
    const distance = previous ? Math.hypot(event.clientX - previous.x, event.clientY - previous.y) : Infinity
    if (previous && now - previous.time < POINTER_SAMPLE_INTERVAL_MS && distance < POINTER_SAMPLE_DISTANCE) return

    this.lastPointerSample = { x: event.clientX, y: event.clientY, time: now }
    this.pointerWakes.push({ x: event.clientX, y: event.clientY, startedAt: now })
    this.pointerWakes = this.pointerWakes.slice(-MAX_POINTER_WAKES)
    this.stopSparkles()
    if (!this.frame) {
      this.animationMode = "pointer"
      this.frame = requestAnimationFrame((time) => this.paintPointer(time))
    }
  }

  paintPointer(time) {
    this.clear()
    if (this.fieldRevealed) this.drawRestingField()
    const active = this.drawPointerWakes(time)
    if (active) {
      this.frame = requestAnimationFrame((next) => this.paintPointer(next))
    } else {
      this.frame = null
      this.animationMode = null
      if (this.fieldRevealed) this.drawStatic()
      else this.clear()
      if (this.element.dataset.edgeWavesState === "quiet" && this.fieldRevealed) this.startSparkles()
    }
  }

  drawPointerWakes(time) {
    this.pointerWakes = (this.pointerWakes || []).filter((wake) => time - wake.startedAt < POINTER_WAVE_DURATION_MS)
    if (!this.pointerWakes.length) return false

    for (const cell of this.visibleCells || []) {
      const centerX = cell.x + cell.size / 2
      const centerY = cell.y + cell.size / 2
      let alpha = 0
      for (const wake of this.pointerWakes) {
        const progress = clamp((time - wake.startedAt) / POINTER_WAVE_DURATION_MS)
        const front = smooth(progress) * POINTER_WAVE_RADIUS
        const distance = Math.hypot(centerX - wake.x, centerY - wake.y)
        const crestDistance = (front - distance) / 38
        const crest = Math.exp(-(crestDistance * crestDistance)) * Math.sin(Math.PI * progress)
        alpha = Math.max(alpha, crest * (0.13 + cell.strength * 0.23))
      }
      this.drawCell(cell, alpha)
    }
    return true
  }

  drawRestingField(opacity = 1) {
    for (const cell of this.visibleCells || []) {
      if (cell.resting) this.drawCell(cell, (0.055 + cell.strength * 0.075) * opacity)
    }
  }

  drawStatic() {
    if (!this.canvasContext) return
    this.clear()
    this.drawRestingField()
  }

  startSparkles() {
    this.stopSparkles()
    if (!this.visibleCells?.length) return
    const sparkle = () => {
      if (this.element.dataset.edgeWavesState !== "quiet" || this.paused || this.motionQuery.matches ||
          document.hidden || !this.visibleCells?.length) return
      this.drawStatic()
      const cells = this.visibleCells || []
      const count = Math.max(1, Math.min(4, Math.round(cells.length / 140)))
      for (let index = 0; index < count && cells.length; index += 1) {
        const cell = cells[Math.floor(Math.random() * cells.length)]
        this.drawCell(cell, 0.22 + Math.random() * 0.14)
      }
      this.sparkleOffTimer = window.setTimeout(() => this.drawStatic(), 170)
      this.sparkleTimer = window.setTimeout(sparkle, 520 + Math.random() * 680)
    }
    this.sparkleTimer = window.setTimeout(sparkle, 420 + Math.random() * 480)
  }

  stopSparkles() {
    window.clearTimeout(this.sparkleTimer)
    window.clearTimeout(this.sparkleOffTimer)
    this.sparkleTimer = null
    this.sparkleOffTimer = null
  }

  clear() {
    this.canvasContext.clearRect(0, 0, this.width || 0, this.height || 0)
  }

  drawCell(cell, alpha) {
    if (alpha < 0.008) return
    this.canvasContext.globalAlpha = clamp(alpha, 0, 0.38)
    this.canvasContext.fillStyle = this.ink
    this.canvasContext.fillRect(Math.round(cell.x), Math.round(cell.y), cell.size, cell.size)
    this.canvasContext.globalAlpha = 1
  }

  setState(state) {
    this.element.dataset.edgeWavesState = state
  }

  syncToggle() {
    if (!this.hasToggleTarget) return
    const unavailable = !this.hero || this.motionQuery.matches
    this.toggleTarget.hidden = unavailable
    const label = this.paused ? "Resume background animation" : "Pause background animation"
    this.toggleTarget.setAttribute("aria-pressed", String(this.paused))
    this.toggleTarget.setAttribute("aria-label", label)
    this.toggleTarget.title = this.paused ? "Resume pixel animation" : "Pause pixel animation"
    if (this.hasToggleLabelTarget) this.toggleLabelTarget.textContent = label
  }

  storedPause() {
    try {
      return sessionStorage.getItem(PAUSE_KEY) === "true"
    } catch {
      return false
    }
  }
}
