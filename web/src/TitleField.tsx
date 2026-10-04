import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react'
import { MAX_ITEM_TITLE } from './api'
import { arrowToLine, focusEnd, lineAbove, lineBelow } from './lines'
import { isPaste, markUnsaved, pastedLines, SAVE_DELAY_MS, singleLine } from './saving'

type Props = {
  value: string
  label: string
  /** Called with a trimmed, non-empty title that differs from `value`. */
  onSave: (title: string) => void
  /** Called when focus leaves the field with no title in it. */
  onClear: () => void
  /** Gets a paste of two or more lines, which leaves the field as it was. */
  onPasteLines: (lines: string[]) => void
}

export function TitleField({ value, label, onSave, onClear, onPasteLines }: Props) {
  // null while not focused, so the field shows `value` and follows changes from the server.
  const [draft, setDraft] = useState<string | null>(null)
  const draftRef = useRef<string | null>(null)
  const timer = useRef<number | undefined>(undefined)
  const saved = useRef<(() => void) | null>(null)
  const latest = useRef({ value, onSave })
  useLayoutEffect(() => {
    latest.current = { value, onSave }
  })

  const flush = useCallback(() => {
    clearTimeout(timer.current)
    saved.current?.()
    saved.current = null
    const title = draftRef.current?.trim()
    if (title && title !== latest.current.value) latest.current.onSave(title)
  }, [])

  useEffect(() => flush, [flush])

  function edit(next: string | null) {
    draftRef.current = next
    setDraft(next)
  }

  function change(next: string, pasted: boolean) {
    edit(singleLine(next))
    clearTimeout(timer.current)
    saved.current ??= markUnsaved()
    timer.current = window.setTimeout(flush, pasted ? 0 : SAVE_DELAY_MS)
  }

  const shown = draft ?? value

  return (
    <span className="title-field" data-value={shown}>
      <textarea
        className="title-input"
        rows={1}
        aria-label={label}
        value={shown}
        maxLength={MAX_ITEM_TITLE}
        enterKeyHint="next"
        onFocus={() => edit(value)}
        onChange={(e) => change(e.target.value, isPaste(e.nativeEvent))}
        onPaste={(e) => {
          const lines = pastedLines(e.clipboardData.getData('text/plain'))
          if (lines.length < 2) return
          e.preventDefault()
          onPasteLines(lines)
        }}
        onKeyDown={(e) => {
          if (e.key === 'Enter') {
            e.preventDefault()
            const below = lineBelow(e.currentTarget)
            if (below) focusEnd(below)
            else e.currentTarget.blur()
          } else if (e.key === 'Escape') {
            e.preventDefault()
            e.currentTarget.blur()
          } else if (e.key === 'Backspace' && e.currentTarget.value === '') {
            // Like an empty line in a text editor: the caret moves to the end of the line above.
            e.preventDefault()
            const above = lineAbove(e.currentTarget)
            if (above) focusEnd(above)
            else e.currentTarget.blur()
          } else {
            arrowToLine(e)
          }
        }}
        onBlur={() => {
          flush()
          // Stays empty rather than showing `value` again while the row leaves.
          if (draftRef.current?.trim() === '') onClear()
          else edit(null)
        }}
      />
    </span>
  )
}
