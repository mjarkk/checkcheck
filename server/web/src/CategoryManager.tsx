import { useLayoutEffect, useState, type FormEvent, type ReactNode } from 'react'
import { MAX_CATEGORY_NAME, type Category, type CategoryOrder } from './api'
import { CategoryRow } from './CategoryRow'
import { ConfirmDialog } from './ConfirmDialog'
import { useListDrag, withGap, type DropTarget } from './drag'
import { CloseIcon } from './icons'
import { captureScroll, layoutPass, motionRef } from './motion'
import { arrange } from './sections'
import { TextField } from './TextField'
import { useModal } from './useModal'

const UNCATEGORIZED = 'none'

const dragIdOf = (category: Category | null) => (category ? String(category.id) : UNCATEGORIZED)

type Props = {
  categories: Category[]
  order: CategoryOrder
  itemCounts: Map<number, number>
  uncategorizedCount: number
  /** Rendered inside the dialog: a modal makes everything outside it inert and hidden behind the backdrop. */
  notice: ReactNode
  onClose: () => void
  onCreate: (name: string) => Promise<boolean>
  onRename: (id: number, name: string) => Promise<boolean>
  onDelete: (id: number) => Promise<void>
  onReorder: (order: CategoryOrder) => void
}

export function CategoryManager({
  categories,
  order,
  itemCounts,
  uncategorizedCount,
  notice,
  onClose,
  onCreate,
  onRename,
  onDelete,
  onReorder,
}: Props) {
  const ref = useModal()
  const [name, setName] = useState('')
  const [pendingDelete, setPendingDelete] = useState<Category | null>(null)
  const entries = arrange(categories, order)

  function drop(dragId: string, target: DropTarget) {
    const moving = entries.find((c) => dragIdOf(c) === dragId)
    if (moving === undefined) return
    const rest = entries.filter((c) => c !== moving)
    rest.splice(target.index, 0, moving)
    const current = entries.map((c) => c?.id ?? null)
    const next = rest.map((c) => c?.id ?? null)
    if (next.some((id, i) => id !== current[i])) onReorder(next)
  }

  const { drag, grab } = useListDrag<string>('category:', drop)

  // The drag re-renders only this dialog, so it runs its own layout passes.
  captureScroll()
  useLayoutEffect(() => layoutPass())

  async function create(e: FormEvent) {
    e.preventDefault()
    const trimmed = name.trim()
    if (trimmed && (await onCreate(trimmed))) setName('')
  }

  function confirmDelete(category: Category) {
    setPendingDelete(null)
    void onDelete(category.id)
  }

  return (
    <dialog
      ref={ref}
      className="dialog dialog-categories"
      aria-labelledby="categories-title"
      data-drag-root=""
      onClose={(e) => {
        // React bubbles the nested confirm dialog's close event up to this handler.
        if (e.target === e.currentTarget) onClose()
      }}
    >
      <div className="dialog-head">
        <h2 id="categories-title" className="dialog-title">
          Categories
        </h2>
        <button className="icon-btn" type="button" aria-label="Close" onClick={() => ref.current?.close()}>
          <CloseIcon />
        </button>
      </div>

      {notice}

      <form className="inline-form" onSubmit={create}>
        <TextField
          id="new-category-name"
          label="New category"
          autoComplete="off"
          enterKeyHint="done"
          maxLength={MAX_CATEGORY_NAME}
          value={name}
          onChange={(e) => setName(e.target.value)}
        />
        <button className="btn btn-tonal btn-large" type="submit" disabled={!name.trim()}>
          Add
        </button>
      </form>

      <ul className={drag ? 'category-list is-spread' : 'category-list'} data-zone="categories">
        {withGap(
          entries,
          'categories',
          drag,
          (c) => dragIdOf(c) === drag?.id,
          (c) => (
            <CategoryRow
              key={dragIdOf(c)}
              category={c}
              dragId={dragIdOf(c)}
              itemCount={c ? (itemCounts.get(c.id) ?? 0) : uncategorizedCount}
              lifted={dragIdOf(c) === drag?.id}
              onRename={(newName) => {
                if (c) void onRename(c.id, newName)
              }}
              onDelete={() => setPendingDelete(c)}
              onGrab={(e) => grab(e, dragIdOf(c))}
            />
          ),
          () => (
            <li
              key="drag-gap"
              ref={motionRef(`category:${drag!.id}`)}
              className="drag-gap"
              style={{ height: drag!.height }}
              aria-hidden="true"
              data-no-ghost=""
            />
          ),
        )}
      </ul>

      {pendingDelete && (
        <ConfirmDialog
          title={`Delete “${pendingDelete.name}”?`}
          message={deleteMessage(itemCounts.get(pendingDelete.id) ?? 0)}
          confirmLabel="Delete"
          onConfirm={() => confirmDelete(pendingDelete)}
          onCancel={() => setPendingDelete(null)}
        />
      )}
    </dialog>
  )
}

function deleteMessage(itemCount: number): string {
  if (itemCount === 0) return 'Its items become uncategorized.'
  return `Its ${itemCount} ${itemCount === 1 ? 'item becomes' : 'items become'} uncategorized.`
}
