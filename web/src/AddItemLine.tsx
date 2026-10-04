import { useEffect, useId, useLayoutEffect, useRef, useState } from 'react'
import { MAX_ITEM_TITLE, type Item } from './api'
import { AddIcon } from './icons'
import { arrowToLine, focusEnd, lineAbove } from './lines'
import { motionRef } from './motion'
import { isPaste, markUnsaved, pastedLines, SAVE_DELAY_MS, singleLine } from './saving'

type Props = {
  motionKey: string
  categoryId: number | null
  label: string
  /** Creates the item as a draft, which stays out of the list until released. Null when it failed. */
  onCreate: (title: string, categoryId: number | null) => Promise<Item | null>
  onRename: (id: number, title: string) => void
  /** Shows a finished draft in the list. */
  onRelease: (id: number) => void
  /** Deletes a draft whose text was cleared. */
  onDiscard: (id: number) => void
  /** Gets a paste of two or more lines, which leaves the line as it was. */
  onPasteLines: (lines: string[]) => void
}

/** One entry typed into the line, from its first character until Enter or blur. */
type Entry = {
  id: number | null
  creating: boolean
  /** The title the server has, or is being sent. */
  sent: string
  finished: boolean
  /** The text when the entry was finished. */
  title: string
}

const newEntry = (): Entry => ({ id: null, creating: false, sent: '', finished: false, title: '' })

export function AddItemLine({
  motionKey,
  categoryId,
  label,
  onCreate,
  onRename,
  onRelease,
  onDiscard,
  onPasteLines,
}: Props) {
  const id = useId()
  const [draft, setDraft] = useState('')
  const draftRef = useRef('')
  const entry = useRef(newEntry())
  const timer = useRef<number | undefined>(undefined)
  const saved = useRef<(() => void) | null>(null)
  // Read from promise callbacks, which outlive the render that started them.
  const props = useRef({ categoryId, onCreate, onRename, onRelease, onDiscard })
  useLayoutEffect(() => {
    props.current = { categoryId, onCreate, onRename, onRelease, onDiscard }
  })

  function setText(text: string) {
    draftRef.current = text
    setDraft(text)
  }

  function stopTimer() {
    clearTimeout(timer.current)
    saved.current?.()
    saved.current = null
  }

  function save(e: Entry, title: string) {
    const p = props.current
    if (!title || title === e.sent) return
    if (e.id !== null) {
      e.sent = title
      p.onRename(e.id, title)
      return
    }
    // A save while creating catches up once the id is known.
    if (e.creating) return
    e.creating = true
    e.sent = title
    void p.onCreate(title, p.categoryId).then((item) => {
      e.creating = false
      if (!item) {
        e.sent = ''
        if (e.finished && !draftRef.current) setText(e.title)
        return
      }
      e.id = item.id
      if (e.finished) settle(e)
      else save(e, draftRef.current.trim())
    })
  }

  function settle(e: Entry) {
    const p = props.current
    if (e.id === null) return
    if (!e.title) {
      p.onDiscard(e.id)
      return
    }
    save(e, e.title)
    p.onRelease(e.id)
  }

  function finish() {
    stopTimer()
    const e = entry.current
    e.title = draftRef.current.trim()
    if (!e.title && e.id === null && !e.creating) return
    e.finished = true
    entry.current = newEntry()
    setText('')
    if (e.id === null && !e.creating) save(e, e.title)
    else settle(e)
  }

  const finishRef = useRef(finish)
  useLayoutEffect(() => {
    finishRef.current = finish
  })
  useEffect(() => () => finishRef.current(), [])

  function change(text: string, pasted: boolean) {
    setText(singleLine(text))
    clearTimeout(timer.current)
    saved.current ??= markUnsaved()
    timer.current = window.setTimeout(
      () => {
        stopTimer()
        save(entry.current, draftRef.current.trim())
      },
      pasted ? 0 : SAVE_DELAY_MS,
    )
  }

  return (
    <li ref={motionRef(motionKey)} className="add-line">
      <label className="add-line-icon" htmlFor={id} aria-hidden="true">
        <AddIcon />
      </label>
      <span className="title-field" data-value={draft}>
        <textarea
          id={id}
          className="title-input"
          rows={1}
          placeholder="Add item"
          aria-label={label}
          value={draft}
          maxLength={MAX_ITEM_TITLE}
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
              finish()
            } else if (e.key === 'Escape') {
              e.preventDefault()
              e.currentTarget.blur()
            } else if (e.key === 'Backspace' && e.currentTarget.value === '') {
              const above = lineAbove(e.currentTarget)
              if (!above) return
              e.preventDefault()
              focusEnd(above)
            } else {
              arrowToLine(e)
            }
          }}
          onBlur={finish}
        />
      </span>
    </li>
  )
}
