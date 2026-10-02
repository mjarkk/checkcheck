import { useModal } from './useModal'

type Props = {
  title: string
  message: string
  confirmLabel: string
  onConfirm: () => void
  onCancel: () => void
}

export function ConfirmDialog({ title, message, confirmLabel, onConfirm, onCancel }: Props) {
  const ref = useModal()

  return (
    <dialog
      ref={ref}
      className="dialog dialog-confirm"
      aria-labelledby="confirm-title"
      aria-describedby="confirm-message"
      onClose={() => (ref.current?.returnValue === 'confirm' ? onConfirm() : onCancel())}
    >
      <form method="dialog">
        <h2 id="confirm-title" className="dialog-title">
          {title}
        </h2>
        <p id="confirm-message" className="dialog-text">
          {message}
        </p>
        <div className="dialog-actions">
          <button className="btn btn-text" value="cancel">
            Cancel
          </button>
          <button className="btn btn-danger" value="confirm">
            {confirmLabel}
          </button>
        </div>
      </form>
    </dialog>
  )
}
