import { useEffect, useId, useRef, useState, type KeyboardEvent, type ReactNode } from 'react'
import { MoreIcon } from './icons'

export type MenuAction = {
  label: string
  icon: ReactNode
  danger?: boolean
  disabled?: boolean
  onSelect: () => void
}

type Props = {
  label: string
  actions: MenuAction[]
}

/** px between the button and the menu, and the least the menu keeps from the viewport's edges. */
const GAP = 4
const EDGE = 8

export function MoreMenu({ label, actions }: Props) {
  const button = useRef<HTMLButtonElement>(null)
  const menu = useRef<HTMLDivElement>(null)
  const [open, setOpen] = useState(false)
  const openAtPress = useRef(false)
  const id = useId()

  function place() {
    const anchor = button.current!.getBoundingClientRect()
    const el = menu.current!
    // offset*, not getBoundingClientRect: the menu is still scaled down by its enter transition.
    const height = el.offsetHeight
    const above = anchor.bottom + GAP + height > window.innerHeight - EDGE && anchor.top - GAP - height >= EDGE
    el.style.top = `${above ? anchor.top - GAP - height : anchor.bottom + GAP}px`
    el.style.left = `${Math.max(EDGE, anchor.right - el.offsetWidth)}px`
    el.style.transformOrigin = above ? 'bottom right' : 'top right'
  }

  useEffect(() => {
    if (!open) return
    const follow = () => place()
    window.addEventListener('scroll', follow, { passive: true })
    window.addEventListener('resize', follow)
    return () => {
      window.removeEventListener('scroll', follow)
      window.removeEventListener('resize', follow)
    }
  }, [open])

  function close() {
    if (menu.current?.matches(':popover-open')) menu.current.hidePopover()
  }

  function toggle() {
    const el = menu.current!
    const pressedOpen = openAtPress.current
    openAtPress.current = false
    // Pressing this button counts as a click outside the menu, which already closed it.
    if (pressedOpen) return
    if (el.matches(':popover-open')) {
      el.hidePopover()
      return
    }
    el.showPopover()
    place()
    items()[0]?.focus()
  }

  function items() {
    return [...menu.current!.querySelectorAll<HTMLButtonElement>('[role="menuitem"]:not(:disabled)')]
  }

  function moveFocus(e: KeyboardEvent) {
    const all = items()
    const at = all.indexOf(document.activeElement as HTMLButtonElement)
    let next: number
    if (e.key === 'ArrowDown') next = (at + 1) % all.length
    else if (e.key === 'ArrowUp') next = (at - 1 + all.length) % all.length
    else if (e.key === 'Home') next = 0
    else if (e.key === 'End') next = all.length - 1
    else return
    e.preventDefault()
    all[next]?.focus()
  }

  return (
    <>
      <button
        ref={button}
        className="icon-btn more-btn"
        type="button"
        aria-label={label}
        title="More"
        aria-haspopup="menu"
        aria-expanded={open}
        aria-controls={id}
        onPointerDown={() => {
          openAtPress.current = menu.current!.matches(':popover-open')
        }}
        onClick={toggle}
      >
        <MoreIcon />
      </button>
      <div
        ref={menu}
        id={id}
        className="menu"
        popover="auto"
        role="menu"
        aria-label={label}
        onToggle={(e) => setOpen(e.newState === 'open')}
        onKeyDown={moveFocus}
        onBlur={(e) => {
          if (!menu.current!.contains(e.relatedTarget)) close()
        }}
      >
        {actions.map((action) => (
          <button
            key={action.label}
            className={action.danger ? 'menu-item is-danger' : 'menu-item'}
            type="button"
            role="menuitem"
            disabled={action.disabled}
            onClick={() => {
              close()
              action.onSelect()
            }}
          >
            {action.icon}
            {action.label}
          </button>
        ))}
      </div>
    </>
  )
}
