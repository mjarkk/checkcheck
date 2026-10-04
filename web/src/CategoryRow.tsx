import { useRef, useState, type PointerEvent } from 'react'
import { flushSync } from 'react-dom'
import { MAX_CATEGORY_NAME, type Category } from './api'
import { DeleteIcon, DragIcon, EditIcon } from './icons'
import { InlineEdit } from './InlineEdit'
import { motionRef } from './motion'

type Props = {
  /** Null for Uncategorized, which can be moved but not renamed or deleted. */
  category: Category | null
  dragId: string
  itemCount: number
  /** Hidden while it is being dragged; it stays mounted so the drag keeps its pointer. */
  lifted: boolean
  onRename: (name: string) => void
  onDelete: () => void
  onGrab: (e: PointerEvent<HTMLElement>) => void
}

export function CategoryRow({ category, dragId, itemCount, lifted, onRename, onDelete, onGrab }: Props) {
  const [editing, setEditing] = useState(false)
  const editButton = useRef<HTMLButtonElement>(null)
  const name = category?.name ?? 'Uncategorized'

  function finishEdit(value: string | null, byKey: boolean) {
    flushSync(() => setEditing(false))
    if (byKey) editButton.current?.focus()
    const trimmed = value?.trim()
    if (trimmed && trimmed !== name) onRename(trimmed)
  }

  let className = 'category-row'
  if (!category) className += ' is-uncategorized'
  if (lifted) className += ' is-lifted'

  return (
    <li ref={lifted ? undefined : motionRef(`category:${dragId}`)} className={className} data-drag-id={dragId}>
      {editing ? (
        <InlineEdit
          className="inline-input category-name-input"
          initial={name}
          label="Category name"
          maxLength={MAX_CATEGORY_NAME}
          onDone={finishEdit}
        />
      ) : (
        <span className="category-name">
          {name}
          <span className="category-count">
            {itemCount} {itemCount === 1 ? 'item' : 'items'}
          </span>
        </span>
      )}
      {category && !editing && (
        <>
          <button
            ref={editButton}
            className="icon-btn"
            type="button"
            aria-label={`Rename ${name}`}
            title="Rename"
            onClick={() => setEditing(true)}
          >
            <EditIcon />
          </button>
          <button
            className="icon-btn icon-btn-danger"
            type="button"
            aria-label={`Delete ${name}`}
            title="Delete"
            onClick={onDelete}
          >
            <DeleteIcon />
          </button>
        </>
      )}
      {/* Pointer-only, so hidden from assistive tech rather than a button that does nothing. */}
      <span className="drag-handle" aria-hidden="true" title="Drag to move" onPointerDown={onGrab}>
        <DragIcon />
      </span>
    </li>
  )
}
