import { useEffect, useState } from 'react'
import { withoutDuplicates } from './saving'

const PATH = '/add'

/** Where pasted lines go: the end of a section's open list, or right after an item. */
export type PasteTarget =
  | { section: { categoryId: number | null; title: string | null } }
  | { item: { id: number; title: string; categoryId: number | null; checked: boolean } }

/** Kept in the history entry, so it has to stay plain data. */
export type Paste = {
  lines: string[]
  /** How many pasted lines were left out for repeating an earlier one. */
  duplicates: number
  target: PasteTarget
  /** Per line, whether it is to be added. */
  checked: boolean[]
}

const stored = (): Paste | null => (location.pathname === PATH ? (history.state?.paste ?? null) : null)

/**
 * The paste the Add items page shows, null elsewhere, and functions that open it, change which
 * lines are checked, and go back to `/`.
 */
export function usePasteRoute(): [
  paste: Paste | null,
  open: (lines: string[], target: PasteTarget) => void,
  choose: (checked: boolean[]) => void,
  close: () => void,
] {
  const [paste, setPaste] = useState(stored)

  useEffect(() => {
    // Without the paste there is nothing to show.
    if (location.pathname === PATH && !stored()) history.replaceState(null, '', '/')
    const onPop = () => setPaste(stored())
    window.addEventListener('popstate', onPop)
    return () => window.removeEventListener('popstate', onPop)
  }, [])

  function open(lines: string[], target: PasteTarget) {
    const unique = withoutDuplicates(lines)
    const next = { lines: unique, duplicates: lines.length - unique.length, target, checked: unique.map(() => true) }
    history.pushState({ pushed: true, paste: next }, '', PATH)
    setPaste(next)
    window.scrollTo(0, 0)
  }

  function choose(checked: boolean[]) {
    if (!paste) return
    const next = { ...paste, checked }
    history.replaceState({ ...history.state, paste: next }, '')
    setPaste(next)
  }

  function close() {
    if (history.state?.pushed) {
      history.back()
      return
    }
    history.replaceState(null, '', '/')
    setPaste(null)
  }

  return [paste, open, choose, close]
}
