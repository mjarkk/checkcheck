import { useState, type FormEvent, type ReactNode } from 'react'
import { MAX_CATEGORY_NAME } from './api'
import { TextField } from './TextField'
import { useModal } from './useModal'

type Props = {
  itemTitle: string
  /** Rendered inside the dialog: a modal makes everything outside it inert and hidden behind the backdrop. */
  notice: ReactNode
  /** Resolves true once the item has a category to move to; the dialog then closes. */
  onSubmit: (name: string) => Promise<boolean>
  onClose: () => void
}

export function NewCategoryDialog({ itemTitle, notice, onSubmit, onClose }: Props) {
  const ref = useModal()
  const [name, setName] = useState('')
  const [busy, setBusy] = useState(false)

  async function submit(e: FormEvent) {
    e.preventDefault()
    const trimmed = name.trim()
    if (!trimmed || busy) return
    setBusy(true)
    const done = await onSubmit(trimmed)
    setBusy(false)
    if (done) ref.current?.close()
  }

  return (
    <dialog ref={ref} className="dialog dialog-confirm" aria-labelledby="new-category-title" onClose={onClose}>
      <form onSubmit={submit}>
        <h2 id="new-category-title" className="dialog-title">
          New category
        </h2>
        {notice}
        <p className="dialog-text">“{itemTitle}” moves into it.</p>
        <TextField
          id="new-category-for-item"
          className="dialog-field"
          label="Name"
          autoComplete="off"
          enterKeyHint="done"
          autoFocus
          maxLength={MAX_CATEGORY_NAME}
          value={name}
          onChange={(e) => setName(e.target.value)}
        />
        <div className="dialog-actions">
          <button className="btn btn-text" type="button" onClick={() => ref.current?.close()}>
            Cancel
          </button>
          <button className="btn btn-filled" type="submit" disabled={!name.trim() || busy}>
            Create
          </button>
        </div>
      </form>
    </dialog>
  )
}
