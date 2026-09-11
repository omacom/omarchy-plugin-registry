// The footer's pixel field, ported from omarchy-site's HeroPixelField
// (variant="field", as used by SiteFooter's PixelBackdrop): the same drifting
// texture — box-blurred noise sampled in two octaves, Bayer ordered dither
// scattered by a fixed jitter tile, cursor glow, and click stamps of the
// square-spiral logo — in the active theme's --t-field-* inks. No wordmark,
// no etch entrance, no music spectrum: a ground, not a signature.
import { Controller } from "@hotwired/stimulus"
import { THEME_EVENT } from "lib/omarchy-theme"

/** Classic 8x8 ordered dither matrix, 0..63. */
const BAYER = [
  0, 32, 8, 40, 2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26, 12, 44, 4, 36,
  14, 46, 6, 38, 60, 28, 52, 20, 62, 30, 54, 22, 3, 35, 11, 43, 1, 33, 9, 41,
  51, 19, 59, 27, 49, 17, 57, 25, 15, 47, 7, 39, 13, 45, 5, 37, 63, 31, 55, 23,
  61, 29, 53, 21,
]

const NOISE_SIZE = 128
/** Grid cells per unit of noise: how big the drifting blobs read. */
const CELLS_PER_NOISE = 9
/** Cursor reach, in grid cells. */
const CURSOR_CELLS = 12
const FIELD_DENSITY = 0.3

/* The footer carries no wordmark, so it aligns to the hero lattice
   horizontally: the same slot the hero wordmark would take. */
const SLOT_INSET = 48
const SLOT_FRACTION = 0.88
const SLOT_MAX = 896
const GLYPH_WIDTH = 81
const GLYPH_HEIGHT = 19
const CLEAR_REACH = 150
const CLEAR_CURVE = 3

const CHARGE_TIME = 1.1
const CHARGE_FROM = 0.45
const CHARGE_GROWTH = 1.6

// The square-spiral logo glyph as a 15x15 bitmap. A click stamps this onto
// the field grid, growing and dissolving through the dither as it fades.
const LOGO_SIZE = 15
const LOGO_ROWS = [
  "111111111111111",
  "100000010000001",
  "101111110001101",
  "101000000000101",
  "101000000000101",
  "101000000000101",
  "101000000000101",
  "111000000000101",
  "101000000000101",
  "101000000000101",
  "101000000000101",
  "101000000000101",
  "101111111111101",
  "100000010000001",
  "111111110111111",
]

function buildNoise(seed) {
  const size = NOISE_SIZE
  let state = seed >>> 0
  const random = () => {
    state = (state * 1664525 + 1013904223) >>> 0
    return state / 4294967296
  }

  let field = new Float32Array(size * size)
  for (let i = 0; i < field.length; i++) field[i] = random()

  // A couple of box passes turn white noise into soft blobs.
  for (let pass = 0; pass < 2; pass++) {
    const next = new Float32Array(size * size)
    for (let y = 0; y < size; y++) {
      for (let x = 0; x < size; x++) {
        let sum = 0
        for (let dy = -1; dy <= 1; dy++) {
          for (let dx = -1; dx <= 1; dx++) {
            const sx = (x + dx + size) % size
            const sy = (y + dy + size) % size
            sum += field[sy * size + sx]
          }
        }
        next[y * size + x] = sum / 9
      }
    }
    field = next
  }

  // Box blurring collapses the range, so stretch it back out.
  let min = Infinity
  let max = -Infinity
  for (const v of field) {
    if (v < min) min = v
    if (v > max) max = v
  }
  const span = max - min || 1
  for (let i = 0; i < field.length; i++) field[i] = (field[i] - min) / span

  return field
}

/** A fixed 64x64 tile of per-cell threshold offsets, tiled over the grid. */
function buildJitter(seed) {
  let state = seed >>> 0
  const tile = new Float32Array(64 * 64)
  for (let i = 0; i < tile.length; i++) {
    state = (state * 1664525 + 1013904223) >>> 0
    tile[i] = state / 4294967296
  }
  return tile
}

function sample(field, x, y) {
  const size = NOISE_SIZE
  const xi = Math.floor(x)
  const yi = Math.floor(y)
  const fx = x - xi
  const fy = y - yi
  const x0 = ((xi % size) + size) % size
  const y0 = ((yi % size) + size) % size
  const x1 = (x0 + 1) % size
  const y1 = (y0 + 1) % size
  const sx = fx * fx * (3 - 2 * fx)
  const sy = fy * fy * (3 - 2 * fy)
  const a = field[y0 * size + x0]
  const b = field[y0 * size + x1]
  const c = field[y1 * size + x0]
  const d = field[y1 * size + x1]
  return (a * (1 - sx) + b * sx) * (1 - sy) + (c * (1 - sx) + d * sx) * sy
}

/** The field's colors come from the active theme's --t-field-* tokens. */
function readPalette() {
  const style = getComputedStyle(document.documentElement)
  const token = (name, fallback) =>
    style.getPropertyValue(name).trim() || fallback
  return {
    bg: token("--t-field-bg", "#0e0e14"),
    dim: token("--t-field-dim", "#39482e"),
    mid: token("--t-field-mid", "#678549"),
    lit: token("--t-field-lit", "#9ece6a"),
  }
}

export default class extends Controller {
  connect() {
    const canvas = this.element.querySelector("canvas")
    const host = canvas?.parentElement
    if (!canvas || !host) return
    const ctx = canvas.getContext("2d", { alpha: false })
    if (!ctx) return

    this.canvas = canvas
    this.host = host
    this.ctx = ctx
    this.reducedMotion = window.matchMedia(
      "(prefers-reduced-motion: reduce)"
    ).matches
    this.finePointer = window.matchMedia(
      "(hover: hover) and (pointer: fine)"
    ).matches
    this.noise = buildNoise(0x9ece6a)
    this.jitter = buildJitter(0x0a1f14)
    this.palette = readPalette()

    // Device-pixel geometry, recomputed on resize. Everything is drawn on
    // whole device pixels so cell edges stay razor sharp at any DPR.
    this.dpr = 1
    this.width = 0
    this.height = 0
    this.cols = 0
    this.rows = 0
    this.wmX = 0
    this.wmY = 0
    this.wmCW = 10
    this.wmCH = 10
    this.cMin = 0
    this.rMin = 0
    this.ramp = new Float32Array(0)

    // Everything the field should stand clear of: the blocks marked as
    // readable. Boxes hug their text, being centred flex children.
    this.quietElements = [
      ...host.parentElement.querySelectorAll("[data-quiet]"),
    ]

    this.pointer = { x: -1e4, y: -1e4 }
    this.visible = true
    this.strength = 0
    this.targetStrength = 0
    this.pings = []
    this.holding = null
    this.frame = 0
    this.lastDraw = 0
    this.disposed = false

    this.onTheme = () => {
      this.palette = readPalette()
      if (this.reducedMotion) this.draw(this.lastDraw)
    }
    this.onPointerMove = (e) => this.pointerMove(e)
    this.onPointerDown = (e) => this.pointerDown(e)
    this.onPointerUp = (e) => this.pointerUp(e)
    this.onPointerCancel = () => {
      this.holding = null
    }
    this.onResize = () => {
      if (!this.measure()) return
      this.startDrawing()
      // Repaint in the same tick as the resize. Waiting for the throttled
      // frame would leave a just-cleared buffer on screen mid-drag.
      this.draw(this.reducedMotion ? 0 : this.lastDraw)
    }

    window.addEventListener(THEME_EVENT, this.onTheme)
    if (this.finePointer) {
      window.addEventListener("pointermove", this.onPointerMove, {
        passive: true,
      })
    }
    // Always attached: stamps work on touch and under reduced motion too.
    window.addEventListener("pointerdown", this.onPointerDown, {
      passive: true,
    })
    window.addEventListener("pointerup", this.onPointerUp, { passive: true })
    window.addEventListener("pointercancel", this.onPointerCancel, {
      passive: true,
    })
    window.addEventListener("contextmenu", this.onPointerCancel, {
      passive: true,
    })

    this.observer = new ResizeObserver(this.onResize)
    this.observer.observe(host)

    // Pause drawing while the field is outside the viewport.
    this.visibility = new IntersectionObserver(
      ([entry]) => {
        this.visible = entry.isIntersecting
        if (this.reducedMotion) return
        if (this.visible && this.frame === 0) {
          this.frame = requestAnimationFrame((t) => this.loop(t))
        } else if (!this.visible && this.frame !== 0) {
          cancelAnimationFrame(this.frame)
          this.frame = 0
        }
      },
      { rootMargin: "64px" }
    )
    // Keep observing zero-size hosts so drawing can start when visible.
    this.visibility.observe(host)

    if (this.measure()) this.startDrawing()
  }

  disconnect() {
    this.disposed = true
    cancelAnimationFrame(this.frame)
    this.frame = 0
    this.observer?.disconnect()
    this.visibility?.disconnect()
    window.removeEventListener(THEME_EVENT, this.onTheme)
    window.removeEventListener("pointermove", this.onPointerMove)
    window.removeEventListener("pointerdown", this.onPointerDown)
    window.removeEventListener("pointerup", this.onPointerUp)
    window.removeEventListener("pointercancel", this.onPointerCancel)
    window.removeEventListener("contextmenu", this.onPointerCancel)
  }

  startDrawing() {
    if (this.drawing) return
    this.drawing = true
    if (this.reducedMotion) this.draw(0)
    else this.frame = requestAnimationFrame((t) => this.loop(t))
  }

  loop(time) {
    if (this.disposed) return
    this.frame = requestAnimationFrame((t) => this.loop(t))
    if (time - this.lastDraw < 25) return
    this.lastDraw = time
    this.draw(time)
  }

  measure() {
    const { canvas, host } = this
    const box = host.getBoundingClientRect()
    if (box.width < 1 || box.height < 1) return false

    const dpr = Math.min(window.devicePixelRatio || 1, 2)
    const nextWidth = Math.round(box.width * dpr)
    const nextHeight = Math.round(box.height * dpr)
    // Assigning canvas.width wipes the buffer, so only do it when the size
    // has actually changed — every needless reset flashes empty background.
    if (nextWidth !== this.width || nextHeight !== this.height) {
      this.width = nextWidth
      this.height = nextHeight
      canvas.width = nextWidth
      canvas.height = nextHeight
    }
    canvas.style.width = `${box.width}px`
    canvas.style.height = `${box.height}px`
    this.dpr = dpr

    // Align the slotless field to the hero lattice horizontally.
    const slotWidth =
      Math.min(SLOT_FRACTION * (box.width - SLOT_INSET), SLOT_MAX) * dpr
    this.wmX = (this.width - slotWidth) / 2
    this.wmY = 0
    this.wmCW = slotWidth / GLYPH_WIDTH
    this.wmCH = slotWidth / GLYPH_WIDTH

    this.cMin = -Math.ceil(this.wmX / this.wmCW) - 1
    this.rMin = -Math.ceil(this.wmY / this.wmCH) - 1
    this.cols = Math.ceil((this.width - this.wmX) / this.wmCW) - this.cMin + 1
    this.rows =
      Math.ceil((this.height - this.wmY) / this.wmCH) - this.rMin + 1

    const quietBoxes = this.quietElements
      .map((el) => el.getBoundingClientRect())
      .filter((rect) => rect.width >= 1 && rect.height >= 1)
      .map((rect) => ({
        l: (rect.left - box.left) * dpr,
        t: (rect.top - box.top) * dpr,
        r: (rect.right - box.left) * dpr,
        b: (rect.bottom - box.top) * dpr,
      }))
    const clearReach = CLEAR_REACH * dpr
    const clearOf = (x, y) => {
      if (quietBoxes.length === 0) return 1
      let nearest = Infinity
      for (const q of quietBoxes) {
        const dx = Math.max(q.l - x, 0, x - q.r)
        const dy = Math.max(q.t - y, 0, y - q.b)
        const dist = Math.sqrt(dx * dx + dy * dy)
        if (dist < nearest) nearest = dist
      }
      if (nearest >= clearReach) return 1
      return (nearest / clearReach) ** CLEAR_CURVE
    }

    const ramp = new Float32Array(this.cols * this.rows)
    for (let r = 0; r < this.rows; r++) {
      const y = this.wmY + (this.rMin + r + 0.5) * this.wmCH
      for (let c = 0; c < this.cols; c++) {
        const x = this.wmX + (this.cMin + c + 0.5) * this.wmCW
        ramp[r * this.cols + c] = FIELD_DENSITY * clearOf(x, y)
      }
    }
    this.ramp = ramp
    return true
  }

  draw(time) {
    const { ctx, palette } = this
    const t = this.reducedMotion ? 0 : time / 1000
    const { width, height, cols, rows, wmX, wmY, wmCW, wmCH } = this

    // The pointer itself is never smoothed: the cells under the cursor are
    // the cells that light. Only the fade in and out is eased.
    this.strength += (this.targetStrength - this.strength) * 0.3

    ctx.fillStyle = palette.bg
    ctx.fillRect(0, 0, width, height)

    const reachOf = (level) => CURSOR_CELLS * wmCW * (0.45 + 0.55 * level)
    const glows =
      this.strength > 0.01
        ? [
            {
              x: this.pointer.x,
              y: this.pointer.y,
              strength: this.strength,
              reach: reachOf(this.strength),
            },
          ]
        : []

    // Resolve each live click stamp once per frame, not once per cell.
    let stamps = []
    if (this.pings.length > 0) {
      this.pings = this.pings.filter((ping) => (time - ping.born) / 1000 < ping.life)
      for (const ping of this.pings) {
        const age = (time - ping.born) / 1000 / ping.life
        const grow = 1 - (1 - age) ** 3
        stamps.push({
          x: ping.x,
          y: ping.y,
          cellPx: wmCW * (ping.from + (ping.to - ping.from) * grow),
          amp: (1 - age) ** 1.7,
        })
      }
    }
    if (this.holding) {
      const charge = Math.min(
        (time - this.holding.start) / 1000 / CHARGE_TIME,
        1
      )
      stamps.push({
        x: this.holding.x,
        y: this.holding.y,
        cellPx: wmCW * (CHARGE_FROM + CHARGE_GROWTH * charge),
        amp: 0.9,
      })
    }

    /** The strongest live stamp covering a device-px point, if any. */
    const stampAt = (cx, cy) => {
      let amp = 0
      for (const stamp of stamps) {
        const lx = Math.floor((cx - stamp.x) / stamp.cellPx + LOGO_SIZE / 2)
        const ly = Math.floor((cy - stamp.y) / stamp.cellPx + LOGO_SIZE / 2)
        if (lx < 0 || ly < 0 || lx >= LOGO_SIZE || ly >= LOGO_SIZE) continue
        if (LOGO_ROWS[ly][lx] === "1" && stamp.amp > amp) amp = stamp.amp
      }
      return amp
    }

    for (let r = 0; r < rows; r++) {
      const row = this.rMin + r
      const yTop = wmY + row * wmCH
      const y = Math.round(yTop)
      const cellH = Math.round(yTop + wmCH) - y
      const cy = yTop + wmCH / 2
      for (let c = 0; c < cols; c++) {
        const col = this.cMin + c
        const shade = this.ramp[r * cols + c]
        let lum = 0

        if (shade > 0.002) {
          const u = col / CELLS_PER_NOISE
          const v = row / CELLS_PER_NOISE
          const base =
            0.6 * sample(this.noise, u + t * 0.14, v - t * 0.055) +
            0.4 *
              sample(this.noise, u * 0.55 - t * 0.08, v * 0.55 + t * 0.06)

          const twinkle =
            0.5 +
            0.5 *
              Math.sin(
                t * 1.1 + this.jitter[(row * 37 + col * 11) & 4095] * 6.283
              )

          lum = shade * (0.3 + 0.52 * base * base + 0.18 * twinkle) * 0.62
        }

        const xLeft = wmX + col * wmCW
        const cx = xLeft + wmCW / 2

        let glowAmount = 0
        for (const glow of glows) {
          const dx = cx - glow.x
          const dy = cy - glow.y
          const dist = Math.sqrt(dx * dx + dy * dy)
          if (dist < glow.reach) {
            const falloff = 1 - dist / glow.reach
            const amount = falloff * falloff * glow.strength
            if (amount > glowAmount) glowAmount = amount
          }
        }
        lum += glowAmount * 0.6

        let waveAmount = 0
        if (stamps.length > 0) {
          waveAmount = stampAt(cx, cy)
          lum += waveAmount * 1.15
        }

        // Pure Bayer would light the same low-index cells everywhere and
        // read as a regular lattice at this density, so a fixed per-cell
        // offset scatters the resting field while the ordered structure
        // still shows up where the cursor pushes luminance high.
        const threshold =
          0.78 * ((BAYER[(row & 7) * 8 + (col & 7)] + 0.5) / 64) +
          0.22 * this.jitter[(row & 63) * 64 + (col & 63)]
        if (lum <= threshold) continue

        const heat = Math.max(glowAmount, waveAmount)
        ctx.fillStyle =
          heat > 0.34 ? palette.lit : heat > 0.1 ? palette.mid : palette.dim
        const x = Math.round(xLeft)
        ctx.fillRect(x, y, Math.round(xLeft + wmCW) - x, cellH)
      }
    }
  }

  /** Distance to the nearest text or control, used to attenuate the glow. */
  nearestTo(list, clientX, clientY) {
    let nearest = Infinity
    for (const el of list) {
      const rect = el.getBoundingClientRect()
      if (rect.width < 1 || rect.height < 1) continue
      const dx = Math.max(rect.left - clientX, 0, clientX - rect.right)
      const dy = Math.max(rect.top - clientY, 0, clientY - rect.bottom)
      const dist = Math.sqrt(dx * dx + dy * dy)
      if (dist < nearest) nearest = dist
    }
    return nearest
  }

  strengthAt(clientX, clientY) {
    const dist = this.nearestTo(this.quietElements, clientX, clientY)
    return dist >= CLEAR_REACH ? 1 : (dist / CLEAR_REACH) ** CLEAR_CURVE
  }

  locate(event) {
    const box = this.host.getBoundingClientRect()
    const inside =
      event.clientX >= box.left &&
      event.clientX <= box.right &&
      event.clientY >= box.top &&
      event.clientY <= box.bottom
    return {
      inside,
      strength: this.strengthAt(event.clientX, event.clientY),
      x: (event.clientX - box.left) * this.dpr,
      y: (event.clientY - box.top) * this.dpr,
    }
  }

  pointerMove(event) {
    if (!this.visible) return
    const { inside, strength, x, y } = this.locate(event)
    // While a press is held the glow stays muted; only a move after it is
    // done wakes it back up.
    if (!this.holding) this.targetStrength = inside ? strength : 0
    if (!inside) return
    this.pointer.x = x
    this.pointer.y = y
    if (this.reducedMotion) this.draw(0)
  }

  /** Exclude interactive controls from field press handling. */
  onControl(target) {
    return (
      target instanceof Element &&
      target.closest(
        'a, button, input, select, textarea, label, [role="button"], header, [data-no-stamp]'
      ) !== null
    )
  }

  pointerDown(event) {
    if (!this.visible) return
    const { inside, x, y } = this.locate(event)
    if (!inside) return
    this.pointer.x = x
    this.pointer.y = y
    if (this.reducedMotion || this.onControl(event.target)) return
    this.targetStrength = 0
    this.holding = { x, y, start: performance.now() }
  }

  pointerUp(event) {
    if (!this.holding) return
    if (this.finePointer) {
      const { inside, strength } = this.locate(event)
      this.targetStrength = inside ? strength : 0
    }
    const now = performance.now()
    const charge = Math.min((now - this.holding.start) / 1000 / CHARGE_TIME, 1)
    const from = CHARGE_FROM + CHARGE_GROWTH * charge
    this.pings = [
      ...this.pings.slice(-3),
      {
        x: this.holding.x,
        y: this.holding.y,
        born: now,
        from,
        to: (from + 1.0 + 3.2 * charge) * (0.92 + Math.random() * 0.16),
        life: (0.65 + 0.55 * charge) * (0.92 + Math.random() * 0.16),
      },
    ]
    this.holding = null
  }
}
