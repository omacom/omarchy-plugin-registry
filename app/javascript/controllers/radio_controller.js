import { Controller } from "@hotwired/stimulus"

const TRACK = {
  title: "We Can Fix Everything (The Ultimate Machine)",
  shortTitle: "We Can Fix Everything",
  artist: "Kevin Koontz",
  src: "/music/kevin_koontz-we_can_fix_everything-1fd24e78693c7450.mp3",
}
const TYPE_INTERVAL_MS = 52
const TYPE_CYCLE_MS = 12000
const VOLUME_STEP = 0.1
const listeners = new Set()
let audio = null
let transport = "stopped"
let wantsPlayback = false
let transportGeneration = 0
let muted = false
let volumeLevel = 0.7
let lastAudibleVolume = volumeLevel

const announce = (change = "state") => listeners.forEach((listener) => listener(change))

const reflectMediaSession = () => {
  if (!("mediaSession" in navigator)) return
  navigator.mediaSession.playbackState = transport === "playing" ? "playing" : "paused"
}

const applyVolume = () => {
  if (!audio) return
  audio.volume = muted ? 0 : volumeLevel
}

const loadPlayer = () => {
  if (audio) return audio
  audio = new Audio(TRACK.src)
  audio.loop = true
  audio.preload = "none"
  applyVolume()
  audio.addEventListener("playing", () => {
    if (!wantsPlayback) {
      audio.pause()
      return
    }
    transport = "playing"
    reflectMediaSession()
    announce()
  })
  audio.addEventListener("pause", () => {
    if (wantsPlayback) return
    if (transport !== "failed") transport = "stopped"
    reflectMediaSession()
    announce()
  })
  audio.addEventListener("waiting", () => {
    if (!wantsPlayback) return
    transport = "loading"
    announce()
  })
  audio.addEventListener("timeupdate", () => announce("progress"))
  audio.addEventListener("loadedmetadata", () => announce("progress"))
  audio.addEventListener("durationchange", () => announce("progress"))
  audio.addEventListener("error", () => {
    transportGeneration += 1
    wantsPlayback = false
    transport = "failed"
    reflectMediaSession()
    announce()
  })
  if ("mediaSession" in navigator && "MediaMetadata" in window) {
    navigator.mediaSession.metadata = new MediaMetadata({ title: TRACK.title, artist: TRACK.artist })
    try {
      navigator.mediaSession.setActionHandler("play", () => { void startPlayback() })
      navigator.mediaSession.setActionHandler("pause", stopPlayback)
    } catch {
    }
  }
  return audio
}

const stopPlayback = () => {
  const player = loadPlayer()
  transportGeneration += 1
  wantsPlayback = false
  player.pause()
  transport = "stopped"
  reflectMediaSession()
  announce()
}

const startPlayback = async () => {
  const player = loadPlayer()
  const generation = ++transportGeneration
  try {
    wantsPlayback = true
    transport = "loading"
    announce()
    await player.play()
  } catch {
    if (generation !== transportGeneration || !wantsPlayback) return
    wantsPlayback = false
    transport = "failed"
    announce()
  }
}

const togglePlayback = () => {
  if (transport === "playing" || transport === "loading") stopPlayback()
  else void startPlayback()
}

const toggleMute = () => {
  if (muted || volumeLevel === 0) {
    muted = false
    volumeLevel = Math.max(VOLUME_STEP, lastAudibleVolume)
  } else {
    lastAudibleVolume = volumeLevel
    muted = true
  }
  applyVolume()
  announce()
}

const adjustVolume = (direction) => {
  const current = muted ? 0 : volumeLevel
  volumeLevel = Math.round(Math.max(0, Math.min(1, current + direction * VOLUME_STEP)) * 10) / 10
  muted = volumeLevel === 0
  if (!muted) lastAudibleVolume = volumeLevel
  applyVolume()
  announce()
}

export default class extends Controller {
  static targets = ["label", "progress", "toggle", "volume"]

  connect() {
    this.wheelAcc = 0
    this.motionQuery = window.matchMedia("(prefers-reduced-motion: reduce)")
    this.compactQuery = window.matchMedia("(max-width: 1130px)")
    this.onUpdate = (change) => change === "progress" ? this.updateProgress() : this.reflect()
    this.onMotion = () => this.reflectTypewriter(true)
    this.onCompact = () => this.reflectTypewriter(true)
    listeners.add(this.onUpdate)
    this.motionQuery.addEventListener("change", this.onMotion)
    this.compactQuery.addEventListener("change", this.onCompact)
    this.reflect()
  }

  disconnect() {
    this.stopTypewriter()
    listeners.delete(this.onUpdate)
    this.motionQuery?.removeEventListener("change", this.onMotion)
    this.compactQuery?.removeEventListener("change", this.onCompact)
  }

  togglePlayback() {
    togglePlayback()
  }

  toggleMute() {
    toggleMute()
  }

  volume(event) {
    const lineHeight = Number.parseFloat(getComputedStyle(this.volumeTarget).lineHeight) || 16
    const pageHeight = this.element.ownerDocument.defaultView?.innerHeight || 800
    const multiplier = event.deltaMode === 1 ? lineHeight : event.deltaMode === 2 ? pageHeight : 1
    this.wheelAcc += (event.deltaY + event.deltaX) * multiplier
    if (Math.abs(this.wheelAcc) < 40) return

    event.preventDefault()
    adjustVolume(this.wheelAcc < 0 ? 1 : -1)
    this.wheelAcc = 0
  }

  volumeKeydown(event) {
    if (!["ArrowUp", "ArrowDown", "Home", "End"].includes(event.key)) return
    event.preventDefault()
    if (event.key === "Home") {
      volumeLevel = 0
      muted = true
      applyVolume()
      announce()
    } else if (event.key === "End") {
      volumeLevel = 1
      muted = false
      lastAudibleVolume = 1
      applyVolume()
      announce()
    } else {
      adjustVolume(event.key === "ArrowUp" ? 1 : -1)
    }
  }

  reflect() {
    const playing = transport === "playing" || transport === "loading"
    const volume = muted ? 0 : volumeLevel
    this.element.dataset.radioState = transport
    this.element.dataset.radioMuted = String(muted)
    this.toggleTarget.setAttribute("aria-pressed", String(playing))
    this.toggleTarget.setAttribute("aria-label",
      transport === "failed" ? "Omarchy radio unavailable" :
        playing ? `Stop Omarchy radio — ${TRACK.artist}, ${TRACK.title}` :
          `Play Omarchy radio — ${TRACK.artist}, ${TRACK.title}`)
    this.volumeTarget.setAttribute("aria-pressed", String(muted))
    this.volumeTarget.setAttribute("aria-label",
      `${muted ? "Unmute" : "Mute"} Omarchy radio; volume ${Math.round(volume * 100)} percent; use arrow keys or mouse wheel to adjust`)
    this.updateProgress()
    this.reflectTypewriter()
  }

  updateProgress() {
    const duration = audio && Number.isFinite(audio.duration) ? audio.duration : 0
    const progress = duration > 0 ? Math.max(0, Math.min(1, audio.currentTime / duration)) : 0
    this.progressTarget.style.transform = `scaleX(${progress})`
  }

  reflectTypewriter(force = false) {
    const playing = transport === "playing" || transport === "loading"
    if (!force && playing === this.typewriterPlaying) return
    this.typewriterPlaying = playing
    this.stopTypewriter()
    if (!playing || this.motionQuery.matches) {
      this.element.dataset.radioTyping = "false"
      this.labelTarget.textContent = this.currentMessage()
      return
    }
    this.element.dataset.radioTyping = "true"
    this.typeCharacter = 0
    this.labelTarget.textContent = ""
    this.typeNextCharacter()
  }

  currentMessage() {
    return this.compactQuery.matches ? TRACK.artist : `${TRACK.artist} — ${TRACK.shortTitle}`
  }

  typeNextCharacter() {
    const message = this.currentMessage()
    this.typeCharacter += 1
    this.labelTarget.textContent = message.slice(0, this.typeCharacter)
    if (this.typeCharacter < message.length) {
      this.typeTimer = window.setTimeout(() => this.typeNextCharacter(), TYPE_INTERVAL_MS)
    } else {
      this.element.dataset.radioTyping = "false"
      const typingTime = message.length * TYPE_INTERVAL_MS
      this.typeTimer = window.setTimeout(() => {
        this.element.dataset.radioTyping = "true"
        this.typeCharacter = 0
        this.labelTarget.textContent = ""
        this.typeNextCharacter()
      }, Math.max(0, TYPE_CYCLE_MS - typingTime))
    }
  }

  stopTypewriter() {
    window.clearTimeout(this.typeTimer)
    this.typeTimer = null
  }
}
