import { useEffect, useRef } from 'react'
import { Checkbox } from './Checkbox'
import { ArrowBackIcon } from './icons'
import type { Paste } from './usePasteRoute'

type Props = {
  paste: Paste
  /** Says where the lines go. */
  message: string
  onChoose: (checked: boolean[]) => void
  onBack: () => void
  /** Gets the checked lines in their order; never empty. */
  onAdd: (lines: string[]) => void
}

export function AddItems({ paste, message, onChoose, onBack, onAdd }: Props) {
  const { lines, duplicates, checked } = paste
  const picked = lines.filter((_, i) => checked[i])
  const ok = useRef<HTMLButtonElement>(null)
  // The bar is pinned to the screen, so this never scrolls; Enter then adds the lines.
  useEffect(() => ok.current?.focus({ preventScroll: true }), [])

  return (
    <>
      <div className="page-head">
        <button className="icon-btn" type="button" aria-label="Back" title="Back" onClick={onBack}>
          <ArrowBackIcon />
        </button>
        <h1 className="page-title">Add items</h1>
      </div>
      <div className="summary">
        <p>
          {message}
          {duplicates > 0 && ` ${duplicatesText(duplicates)}`}
        </p>
      </div>
      <ul className="list">
        {lines.map((line, i) => (
          <li key={i} className="item paste-row">
            <label>
              <Checkbox checked={checked[i]} onChange={(on) => onChoose(checked.with(i, on))} />
              {/* The main rows' title look. */}
              <span className="title-input">{line}</span>
            </label>
          </li>
        ))}
      </ul>
      <div className="paste-bar">
        <button className="btn btn-text" type="button" onClick={onBack}>
          Cancel
        </button>
        <button
          ref={ok}
          className="btn btn-filled"
          type="button"
          disabled={picked.length === 0}
          onClick={() => onAdd(picked)}
        >
          OK
        </button>
      </div>
    </>
  )
}

function duplicatesText(count: number): string {
  return count === 1 ? '1\u00a0duplicate line was left out.' : `${count}\u00a0duplicate lines were left out.`
}
