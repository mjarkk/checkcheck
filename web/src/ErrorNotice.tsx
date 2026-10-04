import { CloseIcon } from './icons'

type Props = {
  message: string
  floating?: boolean
  onDismiss: () => void
}

export function ErrorNotice({ message, floating, onDismiss }: Props) {
  return (
    <div className={floating ? 'notice notice-floating' : 'notice'} role="alert">
      <span className="notice-message">{message}</span>
      <button className="icon-btn" type="button" aria-label="Dismiss" onClick={onDismiss}>
        <CloseIcon />
      </button>
    </div>
  )
}
