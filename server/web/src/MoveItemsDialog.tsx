import { useModal } from './useModal'

export type MoveTarget = { key: string; categoryId: number | null; name: string; count: number }

type Props = {
  message: string
  targets: MoveTarget[]
  onMove: (categoryId: number | null) => void
  onCancel: () => void
}

export function MoveItemsDialog({ message, targets, onMove, onCancel }: Props) {
  const ref = useModal()

  return (
    <dialog
      ref={ref}
      className="dialog dialog-confirm dialog-move"
      aria-labelledby="move-title"
      aria-describedby="move-message"
      onClose={() => {
        const target = targets.find((t) => t.key === ref.current?.returnValue)
        if (target) onMove(target.categoryId)
        else onCancel()
      }}
      onClick={(e) => {
        // Clicks on the dialog's padding target it too; only those outside its box are on the backdrop.
        const box = e.currentTarget.getBoundingClientRect()
        const outside = e.clientX < box.left || e.clientX > box.right || e.clientY < box.top || e.clientY > box.bottom
        if (e.target === e.currentTarget && outside) e.currentTarget.close()
      }}
    >
      <form method="dialog">
        <h2 id="move-title" className="dialog-title">
          Move all items
        </h2>
        <p id="move-message" className="dialog-text">
          {message}
        </p>
        <ul className="move-panel">
          {targets.map((target) => (
            <li key={target.key}>
              <button
                className={target.categoryId === null ? 'move-option is-uncategorized' : 'move-option'}
                value={target.key}
              >
                <span className="category-name">
                  {target.name}
                  <span className="category-count">
                    {target.count} {target.count === 1 ? 'item' : 'items'}
                  </span>
                </span>
              </button>
            </li>
          ))}
        </ul>
        <div className="dialog-actions">
          <button className="btn btn-text" value="cancel">
            Cancel
          </button>
        </div>
      </form>
    </dialog>
  )
}
