export type SpringConfig = { stiffness: number; damping: number }

// Unit mass. Damping is the ratio to critical damping: below 1 overshoots, lower bounces more.
export const SPRINGS = {
  /** Checking, adding, deleting and recategorizing items. */
  layout: { stiffness: 380, damping: 0.72 },
  /** Everything spreading apart when an item is lifted, and closing up again after the drop. */
  spread: { stiffness: 400, damping: 0.56 },
  /** The held row and its neighbours following the pointer before the row tears off. */
  pull: { stiffness: 900, damping: 0.9 },
  /** The neighbours letting go of the row when it tears off. */
  release: { stiffness: 520, damping: 0.4 },
  /** The lifted row catching up with, and then following, the pointer. */
  snap: { stiffness: 620, damping: 0.62 },
  /** The row falling into its gap. */
  drop: { stiffness: 460, damping: 0.56 },
  /** A row flying out of the new-category circle: a long way, so less bounce. */
  fly: { stiffness: 260, damping: 0.8 },
} satisfies Record<string, SpringConfig>

const STEP = 1 / 240

/** How close together checks and deletes must come to hurry the list, and how long it hurries after the last one. */
const HURRY_MS = 500
const HURRY_SPEED = 2

export const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)')

let speed = 1
let lastAction = -Infinity
let calmTimer = 0

/**
 * Call on every check or delete. One within HURRY_MS of the previous one speeds up all motion, CSS
 * animations included, until HURRY_MS passes without another.
 */
export function hurry() {
  const now = performance.now()
  const quick = now - lastAction < HURRY_MS
  lastAction = now
  if (!quick) return
  setSpeed(HURRY_SPEED)
  clearTimeout(calmTimer)
  calmTimer = window.setTimeout(() => setSpeed(1), HURRY_MS)
}

function setSpeed(next: number) {
  speed = next
  // styles.css divides its animation durations by this.
  document.documentElement.style.setProperty('--motion-speed', String(next))
}

export class Spring {
  value: number
  target: number
  velocity = 0
  config: SpringConfig = SPRINGS.layout
  private readonly precision: number

  constructor(value = 0, precision = 0.1) {
    this.value = value
    this.target = value
    this.precision = precision
  }

  /** Advances `dt` seconds; false once it rests on the target. */
  step(dt: number): boolean {
    const atRest =
      Math.abs(this.value - this.target) < this.precision && Math.abs(this.velocity) < this.precision * 10
    if (atRest || reducedMotion.matches) {
      this.value = this.target
      this.velocity = 0
      return false
    }
    const { stiffness, damping } = this.config
    const friction = 2 * damping * Math.sqrt(stiffness)
    for (let left = dt; left > 0; left -= STEP) {
      const h = Math.min(left, STEP)
      this.velocity += (-stiffness * (this.value - this.target) - friction * this.velocity) * h
      this.value += this.velocity * h
    }
    return true
  }
}

type Animation = { tick(dt: number): boolean }

const running = new Set<Animation>()
let frame = 0
let lastFrame = 0

/** Ticks `animation` every frame until its `tick` returns false. */
export function run(animation: Animation) {
  running.add(animation)
  if (frame) return
  lastFrame = performance.now()
  frame = requestAnimationFrame(loop)
}

function loop(now: number) {
  // Capped so a stalled or backgrounded tab resumes the motion instead of skipping to its end.
  const dt = Math.min(Math.max(now - lastFrame, 0) / 1000, 1 / 30)
  lastFrame = now
  for (const animation of running) if (!animation.tick(dt * speed)) running.delete(animation)
  frame = running.size ? requestAnimationFrame(loop) : 0
}

type Point = { left: number; top: number }

/** Where something is drawn on screen: its unscaled box's viewport position, its scale, and their velocities. */
export type Visual = { left: number; top: number; scale: number; vx: number; vy: number; vscale: number }

export class Motion implements Animation {
  el: HTMLElement | null = null
  ghost: HTMLElement | null = null
  /** The modal dialog the element lives in, which then scrolls it instead of the window; null on the page. */
  layer: HTMLElement | null = null
  /** Position of the untransformed box at the last layout pass, in its layer's scrolled content. */
  last: Point | null = null
  width = 0
  readonly x = new Spring()
  readonly y = new Spring()
  readonly scale = new Spring(1, 0.001)

  configure(config: SpringConfig) {
    this.x.config = config
    this.y.config = config
    this.scale.config = config
  }

  tick(dt: number) {
    const moving = [this.x.step(dt), this.y.step(dt), this.scale.step(dt)].includes(true)
    this.write()
    return moving
  }

  write() {
    if (!this.el) return
    const x = this.x.value
    const y = this.y.value
    const scale = this.scale.value
    this.el.style.transform = x || y || scale !== 1 ? `translate3d(${x}px, ${y}px, 0) scale(${scale})` : ''
  }
}

const motions = new Map<string, Motion>()
const refs = new Map<string, (el: HTMLElement | null) => (() => void) | undefined>()
/** Target key → source key whose last position a newly mounted element starts from. */
const inherited = new Map<string, string>()

type PassOptions = {
  /** Scroll so this element stays where it was on screen. */
  anchor?: string
  config?: SpringConfig
  /** Start this element from `visual`, or shrunk to `scale` around viewport `point`, instead of its previous position. */
  drop?: { key: string; visual: Visual } | { key: string; point: { x: number; y: number }; scale: number }
}

let nextPass: PassOptions = {}
let scrollMark = 0

/**
 * Ref callback that springs the element from where it was drawn to where the next layout pass finds
 * it, also when it remounts elsewhere under the same key. Keys must be unique among mounted elements,
 * and registered elements must not be nested: a parent's transform would read as the child's movement.
 */
export function motionRef(key: string) {
  let ref = refs.get(key)
  if (!ref) {
    ref = (el) => {
      if (!el) return
      attach(key, el)
      return () => detach(key, el)
    }
    refs.set(key, ref)
  }
  return ref
}

function attach(key: string, el: HTMLElement) {
  let m = motions.get(key)
  if (!m) {
    m = new Motion()
    motions.set(key, m)
  }
  m.el = el
  m.ghost = null
  m.layer = el.closest('dialog')
  el.dataset.motionKey = key
  // A remount carries on the old element's motion, so it must not also play its enter animation.
  if (m.last || inherited.has(key)) el.dataset.entered = ''
}

function detach(key: string, el: HTMLElement) {
  const m = motions.get(key)
  if (m?.el !== el) return
  m.el = null
  // Cloned now: by the next layout pass React has taken the element out of the document.
  if (m.last && !('noGhost' in el.dataset)) m.ghost = cloneVisual(el)
}

/** Call while rendering the component whose commits `layoutPass` animates: scrolling a commit causes is measured from here. */
export function captureScroll() {
  scrollMark = window.scrollY
}

/** Options for the next animated `layoutPass` only. */
export function prepareLayoutPass(options: PassOptions) {
  nextPass = options
}

/** The element mounting under `to` starts from where `from` was, instead of entering. */
export function inheritMotion(from: string, to: string) {
  inherited.set(to, from)
}

export function motionOf(key: string): Motion | undefined {
  return motions.get(key)
}

/** Springs the element towards an offset from its layout position. */
export function pullTo(key: string, x: number, y: number, config: SpringConfig) {
  const m = motions.get(key)
  if (!m) return
  m.configure(config)
  m.x.target = x
  m.y.target = y
  run(m)
}

/**
 * The element's viewport box as laid out, ignoring its own transforms: motion's, and the enter
 * animations' translate and scale. Its parent must not be transformed. All zero while not rendered.
 */
export function layoutRect(el: HTMLElement) {
  const parent = el.parentElement
  if (!el.offsetParent || !parent) return { left: 0, top: 0, width: 0, height: 0 }
  const base = parent.getBoundingClientRect()
  const size = { width: el.offsetWidth, height: el.offsetHeight }
  if (el.offsetParent === parent) {
    return {
      left: base.left + parent.clientLeft - parent.scrollLeft + el.offsetLeft,
      top: base.top + parent.clientTop - parent.scrollTop + el.offsetTop,
      ...size,
    }
  }
  return { left: base.left + el.offsetLeft - parent.offsetLeft, top: base.top + el.offsetTop - parent.offsetTop, ...size }
}

function scrollOf(layer: HTMLElement | null, pageTop: number) {
  return layer ? { left: layer.scrollLeft, top: layer.scrollTop } : { left: window.scrollX, top: pageTop }
}

/**
 * Measures every registered element. With `animate`, each one that moved since the previous pass is
 * put back where it was on screen and springs to its new place, and removed ones fade out.
 * Run it after every commit that can move registered elements.
 */
export function layoutPass(animate = true) {
  const { anchor, config = SPRINGS.layout, drop } = animate ? nextPass : {}
  if (animate) nextPass = {}

  const measuredAt = window.scrollY
  const boxes = new Map<Motion, Point & { width: number; height: number }>()
  for (const m of motions.values()) {
    if (!m.el) continue
    const box = layoutRect(m.el)
    if (!box.width && !box.height) continue
    boxes.set(m, box)
    m.width = box.width
  }

  for (const [to, from] of inherited) {
    const m = motions.get(to)
    if (!m?.el) continue
    m.last ??= motions.get(from)?.last ?? null
    inherited.delete(to)
  }

  if (anchor) {
    const m = motions.get(anchor)
    const box = m && boxes.get(m)
    // From scrollMark, not measuredAt: the browser's own scroll anchoring may already have scrolled.
    if (box && m.last && !m.layer) window.scrollTo(window.scrollX, scrollMark + box.top + measuredAt - m.last.top)
  }
  const scroll = window.scrollY
  const scrolled = scroll - scrollMark

  for (const [key, m] of motions) {
    const box = boxes.get(m)
    if (!box) continue
    const offset = scrollOf(m.layer, measuredAt)
    const now = { left: box.left + offset.left, top: box.top + offset.top }
    if (drop?.key === key) {
      const top = m.layer ? box.top : box.top - (scroll - measuredAt)
      if ('visual' in drop) {
        const { visual } = drop
        m.x.value = visual.left - box.left
        m.y.value = visual.top - top
        m.scale.value = visual.scale
        m.x.velocity = visual.vx
        m.y.velocity = visual.vy
        m.scale.velocity = visual.vscale
      } else {
        m.x.value = drop.point.x - (box.left + box.width / 2)
        m.y.value = drop.point.y - (top + box.height / 2)
        m.scale.value = drop.scale
      }
      m.configure('visual' in drop ? SPRINGS.drop : SPRINGS.fly)
    } else if (animate && m.last && !reducedMotion.matches) {
      const dx = m.last.left - now.left
      const dy = m.last.top - now.top + (m.layer ? 0 : scrolled)
      if (Math.abs(dx) >= 0.5 || Math.abs(dy) >= 0.5) {
        m.x.value += dx
        m.y.value += dy
        m.configure(config)
      }
    }
    m.last = now
    m.write()
    run(m)
  }

  for (const [key, m] of motions) {
    if (m.el) continue
    if (animate && m.ghost && m.last) fadeOut(m)
    motions.delete(key)
    refs.delete(key)
  }
  scrollMark = scroll
}

function fadeOut(m: Motion) {
  const ghost = m.ghost!
  const last = m.last!
  const offset = scrollOf(m.layer, scrollMark)
  ghost.classList.add('motion-ghost')
  ghost.style.left = `${last.left - offset.left + m.x.value}px`
  ghost.style.top = `${last.top - offset.top + m.y.value}px`
  ghost.style.width = `${m.width}px`
  ;(m.layer ?? document.body).append(ghost)
  const remove = () => ghost.remove()
  ghost
    .animate([{ opacity: 1 }, { opacity: 0, scale: 0.94 }], { duration: 200 / speed, easing: 'ease-in' })
    .finished.then(remove, remove)
}

/** A detached, inert copy of `el` that shows the same field values. */
export function cloneVisual(el: HTMLElement): HTMLElement {
  const copy = el.cloneNode(true) as HTMLElement
  const fields = el.querySelectorAll<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>('input, textarea, select')
  const copies = copy.querySelectorAll<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>('input, textarea, select')
  fields.forEach((field, i) => {
    const target = copies[i]
    if (field instanceof HTMLInputElement && target instanceof HTMLInputElement) target.checked = field.checked
    else target.value = field.value
  })
  for (const node of [copy, ...copy.querySelectorAll('[id]')]) node.removeAttribute('id')
  delete copy.dataset.motionKey
  copy.setAttribute('aria-hidden', 'true')
  copy.inert = true
  copy.style.transform = ''
  for (const node of [copy, ...copy.querySelectorAll<HTMLElement | SVGElement>('*')]) node.style.animation = 'none'
  return copy
}
