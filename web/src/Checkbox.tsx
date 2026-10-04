type Props = {
  id?: string
  className?: string
  label?: string
  checked: boolean
  onChange: (checked: boolean) => void
}

export function Checkbox({ id, className, label, checked, onChange }: Props) {
  return (
    <span className={className ? `checkbox ${className}` : 'checkbox'}>
      <input
        id={id}
        className="checkbox-input"
        type="checkbox"
        checked={checked}
        aria-label={label}
        onChange={(e) => onChange(e.target.checked)}
      />
      <span className="checkbox-box" aria-hidden="true">
        <svg viewBox="0 0 24 24">
          <path d="M5.5 12.5l4.2 4.2 8.8-9.4" pathLength={1} />
        </svg>
      </span>
    </span>
  )
}
