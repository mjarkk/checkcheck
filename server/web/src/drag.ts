import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type Dispatch,
  type PointerEvent as ReactPointerEvent,
  type ReactNode,
  type SetStateAction,
} from 'react'
import { flushSync } from 'react-dom'
import { cloneVisual, layoutRect, motionOf, prepareLayoutPass, pullTo, run, Spring, SPRINGS, type Visual } from './motion'

/** Pointer travel (px) at which a held row lets go of its neighbours and follows the pointer. */
const TEAR_DISTANCE = 56
/** Before tearing off, the row moves this fraction of the pointer's travel, less the further it is pulled. */
const RESISTANCE = 0.5
const RESISTANCE_FALLOFF = 140
/** How far the 1st, 2nd and 3rd line away from the held row are dragged along, relative to the row. */
const NEIGHBOUR_PULL = [0.45, 0.2, 0.08]
const LIFT_SCALE = 1.03
/** Scale of the lifted row while it is drawn into the new-category circle. */
const ATTRACT_SCALE = 0.08
/** Within this distance (px) of the scrolled area's top or bottom edge a drag scrolls it. */
const SCROLL_EDGE = 96
/** px/s, reached at the very edge. */
const MAX_SCROLL_SPEED = 1400
const LIFTED_SHADOW = '0 1px 3px rgb(0 0 0 / 0.3), 0 4px 8px 3px rgb(0 0 0 / 0.15)'

/** The zone of a drop on the element marked `data-new-category`: the item goes to a category yet to be named. */
export const NEW_CATEGORY_ZONE = 'new-category'

export type DropTarget = { zone: string; index: number }

/** A lifted row: render a gap of `height` px before the `index`-th row of `zone`, not counting this one. */
export type Drag<Id> = { id: Id; height: number; target: DropTarget }

/**
 * Dragging rows by a handle. Rows carry `data-drag-id`, are registered with `motionRef` under
 * `keyPrefix` + id, and sit directly in a list element with `data-zone`, all inside an element with
 * `data-drag-root` (which may also hold a `data-new-category` drop circle). While a row is lifted,
 * hide it (it stays mounted) and render the gap that `drag` describes, e.g. with `withGap`.
 */
export function useListDrag<Id extends string | number>(keyPrefix: string, onDrop: (id: Id, target: DropTarget) => void) {
  const [drag, setDrag] = useState<Drag<Id> | null>(null)
  const onDropRef = useRef(onDrop)
  useLayoutEffect(() => {
    onDropRef.current = onDrop
  })
  const session = useRef<DragSession<Id> | null>(null)
  useEffect(() => () => session.current?.dispose(), [])

  const grab = useCallback(
    (e: ReactPointerEvent<HTMLElement>, id: Id) => {
      if (session.current || !e.isPrimary || e.button !== 0) return
      const row = e.currentTarget.closest<HTMLElement>('[data-drag-id]')
      const root = row?.closest<HTMLElement>('[data-drag-root]')
      if (!row?.parentElement?.dataset.zone || !root) return
      // Keeps focus and text selection where they are.
      e.preventDefault()
      session.current = new DragSession(id, `${keyPrefix}${id}`, row, root, e.nativeEvent, {
        setDrag,
        drop: (target) => onDropRef.current(id, target),
        end: () => {
          session.current = null
        },
      })
    },
    [keyPrefix],
  )

  return { drag, grab }
}

/**
 * `rows` rendered in order with the drag's gap where it targets `zone`. Rows for which `hidden` holds
 * stay in place but aren't counted: moving the lifted row's node would drop the drag's pointer.
 */
export function withGap<T>(
  rows: T[],
  zone: string,
  drag: Drag<unknown> | null,
  hidden: (row: T) => boolean,
  renderRow: (row: T) => ReactNode,
  renderGap: () => ReactNode,
): ReactNode[] {
  const gapAt = drag?.target.zone === zone ? drag.target.index : -1
  const out: ReactNode[] = []
  let visible = 0
  for (const row of rows) {
    if (!hidden(row) && visible++ === gapAt) out.push(renderGap())
    out.push(renderRow(row))
  }
  if (visible === gapAt) out.push(renderGap())
  return out
}

type Host<Id> = {
  setDrag: Dispatch<SetStateAction<Drag<Id> | null>>
  drop: (target: DropTarget) => void
  end: () => void
}

type Neighbour = { key: string; weight: number }

class DragSession<Id> {
  private readonly pointerId: number
  private readonly start: { x: number; y: number }
  private pointer: { x: number; y: number }
  /** Pointer position within the row, kept while the row follows the pointer. */
  private readonly grabOffset: { x: number; y: number }
  private readonly neighbours: Neighbour[]
  /** The modal dialog holding the list: it scrolls instead of the window and draws the lifted row. */
  private readonly layer: HTMLElement | null
  private readonly capture: HTMLElement
  private overlay: Overlay | null = null
  private origin: DropTarget | null = null
  private target: DropTarget | null = null
  private frame = 0
  private lastFrame = 0
  private scrollCarry = 0
  private readonly id: Id
  private readonly key: string
  private readonly row: HTMLElement
  private readonly root: HTMLElement
  private readonly host: Host<Id>

  constructor(id: Id, key: string, row: HTMLElement, root: HTMLElement, e: PointerEvent, host: Host<Id>) {
    this.id = id
    this.key = key
    this.row = row
    this.root = root
    this.host = host
    this.layer = row.closest('dialog')
    // The handle's row is hidden once lifted, so something that stays receives the pointer; outside
    // an open modal everything is inert.
    this.capture = this.layer ?? document.documentElement
    this.pointerId = e.pointerId
    this.start = { x: e.clientX, y: e.clientY }
    this.pointer = this.start
    const box = layoutRect(row)
    this.grabOffset = { x: e.clientX - box.left, y: e.clientY - box.top }

    const lines = [...row.parentElement!.children].filter(
      (el): el is HTMLElement => el instanceof HTMLElement && !!el.dataset.motionKey,
    )
    const at = lines.indexOf(row)
    this.neighbours = lines.flatMap((el, i) => {
      const weight = NEIGHBOUR_PULL[Math.abs(i - at) - 1]
      return weight ? [{ key: el.dataset.motionKey!, weight }] : []
    })

    this.capture.setPointerCapture(e.pointerId)
    window.addEventListener('pointermove', this.onMove)
    window.addEventListener('pointerup', this.onUp)
    window.addEventListener('pointercancel', this.onCancel)
    window.addEventListener('blur', this.onCancel)
    // Capturing, so Escape cancels the drag before it can close a dialog.
    window.addEventListener('keydown', this.onKey, true)
    document.body.classList.add('is-grabbing')
  }

  /** Stops without touching React state, for when the list unmounts mid-drag. */
  dispose() {
    this.removeListeners()
    cancelAnimationFrame(this.frame)
    this.overlay?.remove()
    document.body.classList.remove('is-dragging')
  }

  private onMove = (e: PointerEvent) => {
    if (e.pointerId !== this.pointerId) return
    this.pointer = { x: e.clientX, y: e.clientY }
    if (this.overlay) this.follow()
    else this.pull()
  }

  private onUp = (e: PointerEvent) => {
    if (e.pointerId === this.pointerId) this.finish(false)
  }

  private onCancel = () => this.finish(true)

  private onKey = (e: KeyboardEvent) => {
    if (e.key !== 'Escape') return
    e.preventDefault()
    e.stopPropagation()
    this.finish(true)
  }

  private removeListeners() {
    window.removeEventListener('pointermove', this.onMove)
    window.removeEventListener('pointerup', this.onUp)
    window.removeEventListener('pointercancel', this.onCancel)
    window.removeEventListener('blur', this.onCancel)
    window.removeEventListener('keydown', this.onKey, true)
    if (this.capture.hasPointerCapture(this.pointerId)) this.capture.releasePointerCapture(this.pointerId)
    document.body.classList.remove('is-grabbing')
  }

  private pull() {
    const dx = this.pointer.x - this.start.x
    const dy = this.pointer.y - this.start.y
    const distance = Math.hypot(dx, dy)
    if (distance >= TEAR_DISTANCE) {
      this.lift()
      return
    }
    const k = RESISTANCE / (1 + distance / RESISTANCE_FALLOFF)
    pullTo(this.key, dx * k, dy * k, SPRINGS.pull)
    for (const n of this.neighbours) pullTo(n.key, dx * k * n.weight, dy * k * n.weight, SPRINGS.pull)
  }

  private follow() {
    this.overlay!.follow(this.pointer.x - this.grabOffset.x, this.pointer.y - this.grabOffset.y)
  }

  private lift() {
    const rect = this.row.getBoundingClientRect()
    const height = this.row.offsetHeight
    const m = motionOf(this.key)
    const clone = cloneVisual(this.row)
    clone.classList.add('drag-overlay')
    clone.style.width = `${this.row.offsetWidth}px`
    this.overlay = new Overlay(clone, this.layer ?? document.body, rect, m?.x.velocity ?? 0, m?.y.velocity ?? 0)
    this.follow()

    for (const n of this.neighbours) pullTo(n.key, 0, 0, SPRINGS.release)
    // The gap takes over this key; it starts where the row's layout box is.
    if (m) {
      for (const s of [m.x, m.y]) {
        s.value = 0
        s.target = 0
        s.velocity = 0
      }
    }

    const zone = this.row.parentElement!
    const index = this.rowsOf(zone).filter((row) => row.compareDocumentPosition(this.row) & Node.DOCUMENT_POSITION_FOLLOWING).length
    const origin = { zone: zone.dataset.zone!, index }
    this.origin = origin
    this.target = origin
    document.body.classList.add('is-dragging')
    prepareLayoutPass({ anchor: this.key, config: SPRINGS.spread })
    flushSync(() => this.host.setDrag({ id: this.id, height, target: origin }))

    this.lastFrame = performance.now()
    this.frame = requestAnimationFrame(this.onFrame)
  }

  /** The zone's rendered rows other than the dragged one. */
  private rowsOf(zone: HTMLElement): HTMLElement[] {
    return [...zone.querySelectorAll<HTMLElement>(':scope > [data-drag-id]')].filter(
      (row) => row !== this.row && row.offsetParent !== null,
    )
  }

  private onFrame = (now: number) => {
    const dt = Math.min(Math.max(now - this.lastFrame, 0) / 1000, 1 / 30)
    this.lastFrame = now
    // The new-category circle sits in the bottom scroll edge; hovering it must not scroll.
    const circle = this.newCategoryCircle()
    this.overlay!.attract(circle)
    if (!circle) this.autoScroll(dt)
    const target = circle ? { zone: NEW_CATEGORY_ZONE, index: 0 } : this.hitTest()
    if (target && (target.zone !== this.target!.zone || target.index !== this.target!.index)) {
      this.target = target
      flushSync(() => this.host.setDrag((d) => d && { ...d, target }))
    }
    this.frame = requestAnimationFrame(this.onFrame)
  }

  private autoScroll(dt: number) {
    const area = this.layer?.getBoundingClientRect() ?? { top: 0, bottom: window.innerHeight }
    const edge = Math.min(SCROLL_EDGE, (area.bottom - area.top) / 4)
    const y = this.pointer.y
    const depth = y < area.top + edge ? y - (area.top + edge) : y > area.bottom - edge ? y - (area.bottom - edge) : 0
    if (!depth) {
      this.scrollCarry = 0
      return
    }
    const strength = Math.min(Math.abs(depth) / edge, 1) ** 2
    // Browsers drop sub-pixel scrolls, so slow speeds accumulate until they add up to a pixel.
    this.scrollCarry += Math.sign(depth) * strength * MAX_SCROLL_SPEED * dt
    const whole = Math.trunc(this.scrollCarry)
    if (whole) {
      ;(this.layer ?? window).scrollBy(0, whole)
      this.scrollCarry -= whole
    }
  }

  /** The new-category circle's centre while the pointer is on it. */
  private newCategoryCircle(): { x: number; y: number } | null {
    const circle = this.root.querySelector<HTMLElement>('[data-new-category]')
    if (!circle) return null
    const rect = circle.getBoundingClientRect()
    const centre = { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 }
    const over = Math.hypot(this.pointer.x - centre.x, this.pointer.y - centre.y) <= rect.width / 2 + 16
    return over ? centre : null
  }

  /** The zone nearest the pointer, and how many of its rows lie above the pointer. */
  private hitTest(): DropTarget | null {
    const y = this.pointer.y
    let best: HTMLElement | null = null
    let bestDistance = Infinity
    for (const zone of this.root.querySelectorAll<HTMLElement>('[data-zone]')) {
      const rect = zone.getBoundingClientRect()
      const distance = y < rect.top ? rect.top - y : y > rect.bottom ? y - rect.bottom : 0
      if (distance < bestDistance) {
        best = zone
        bestDistance = distance
      }
    }
    if (!best) return null
    const index = this.rowsOf(best).filter((row) => {
      const box = layoutRect(row)
      return box.top + box.height / 2 < y
    }).length
    return { zone: best.dataset.zone!, index }
  }

  private finish(cancel: boolean) {
    this.removeListeners()
    const overlay = this.overlay
    if (!overlay) {
      pullTo(this.key, 0, 0, SPRINGS.release)
      for (const n of this.neighbours) pullTo(n.key, 0, 0, SPRINGS.release)
      this.host.end()
      return
    }
    cancelAnimationFrame(this.frame)
    const target = cancel ? this.origin! : this.target!
    if (target.zone === NEW_CATEGORY_ZONE) {
      overlay.vanish()
      // The row stays hidden until the category is named, so keep what's on screen still instead.
      prepareLayoutPass({ anchor: this.firstVisibleKey(), config: SPRINGS.spread })
    } else {
      prepareLayoutPass({ anchor: this.key, config: SPRINGS.spread, drop: { key: this.key, visual: overlay.visual() } })
    }
    flushSync(() => {
      this.host.setDrag(null)
      if (!cancel) this.host.drop(target)
    })
    if (target.zone !== NEW_CATEGORY_ZONE) {
      overlay.remove()
      motionOf(this.key)?.el?.animate([{ boxShadow: LIFTED_SHADOW }, { boxShadow: 'none' }], {
        duration: 400,
        easing: 'ease-out',
      })
    }
    document.body.classList.remove('is-dragging')
    this.host.end()
  }

  private firstVisibleKey(): string | undefined {
    for (const el of this.root.querySelectorAll<HTMLElement>('[data-motion-key]')) {
      if (el.getBoundingClientRect().bottom > 0) return el.dataset.motionKey
    }
    return undefined
  }
}

/** The lifted row: a copy in a fixed layer that springs after the pointer. */
class Overlay {
  private readonly x: Spring
  private readonly y: Spring
  private readonly scale = new Spring(1, 0.001)
  private removed = false
  private readonly el: HTMLElement
  private goal = { left: 0, top: 0 }
  private attractor: { x: number; y: number } | null = null

  constructor(el: HTMLElement, parent: HTMLElement, from: DOMRect, vx: number, vy: number) {
    this.el = el
    this.x = new Spring(from.left)
    this.y = new Spring(from.top)
    this.x.velocity = vx
    this.y.velocity = vy
    for (const s of [this.x, this.y, this.scale]) s.config = SPRINGS.snap
    this.scale.target = LIFT_SCALE
    parent.append(el)
    this.write()
    run(this)
  }

  follow(left: number, top: number) {
    this.goal = { left, top }
    this.retarget()
  }

  /** Draws the row into viewport point `at` instead of following the pointer, until called with null. */
  attract(at: { x: number; y: number } | null) {
    if (at?.x === this.attractor?.x && at?.y === this.attractor?.y) return
    this.attractor = at
    this.retarget()
  }

  private retarget() {
    if (this.attractor) {
      this.x.target = this.attractor.x - this.el.offsetWidth / 2
      this.y.target = this.attractor.y - this.el.offsetHeight / 2
      this.scale.target = ATTRACT_SCALE
    } else {
      this.x.target = this.goal.left
      this.y.target = this.goal.top
      this.scale.target = LIFT_SCALE
    }
    run(this)
  }

  visual(): Visual {
    return {
      left: this.x.value,
      top: this.y.value,
      scale: this.scale.value,
      vx: this.x.velocity,
      vy: this.y.velocity,
      vscale: this.scale.velocity,
    }
  }

  tick(dt: number) {
    if (this.removed) return false
    const moving = [this.x.step(dt), this.y.step(dt), this.scale.step(dt)].includes(true)
    this.write()
    return moving
  }

  /** Shrinks the rest of the way into the point it is attracted to while fading out, then removes itself. */
  vanish() {
    this.scale.target = ATTRACT_SCALE / 2
    run(this)
    const remove = () => this.remove()
    this.el
      .animate([{ opacity: 1 }, { opacity: 0 }], { duration: 240, delay: 80, easing: 'ease-in', fill: 'forwards' })
      .finished.then(remove, remove)
  }

  remove() {
    this.removed = true
    this.el.remove()
  }

  private write() {
    this.el.style.transform = `translate3d(${this.x.value}px, ${this.y.value}px, 0) scale(${this.scale.value})`
  }
}
