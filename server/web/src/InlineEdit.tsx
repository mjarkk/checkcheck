import { useRef, useState } from 'react'
import { CheckIcon } from './icons'

type Props = {
  initial: string
  label: string
  maxLength: number
  className?: string
  /** `value` is null when cancelled; `byKey` is true for Enter/Escape/the apply button and false when focus simply left. */
  onDone: (value: string | null, byKey: boolean) => void
}

/** Autofocused; Enter, the apply button and leaving the field apply the value, Escape cancels. */
export function InlineEdit({ initial, label, maxLength, className, onDone }: Props) {
  const [value, setValue] = useState(initial)
  // Unmounting a focused input fires blur in some browsers; without this guard Escape would still save.
  const finished = useRef(false)

  function finish(result: string | null, byKey: boolean) {
    if (finished.current) return
    finished.current = true
    onDone(result, byKey)
  }

  return (
    <>
      <input
        className={className}
        aria-label={label}
        value={value}
        maxLength={maxLength}
        enterKeyHint="done"
        autoFocus
        onFocus={(e) => e.currentTarget.select()}
        onChange={(e) => setValue(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === 'Enter') {
            e.preventDefault()
            finish(value, true)
          } else if (e.key === 'Escape') {
            // Also keeps an enclosing <dialog> open.
            e.preventDefault()
            finish(null, true)
          }
        }}
        onBlur={() => finish(value, false)}
      />
      <button
        className="icon-btn icon-btn-primary"
        type="button"
        aria-label="Apply"
        title="Apply"
        // Keeps focus in the input: a blur would apply first, and the click would then land on
        // whatever button replaced this one.
        onPointerDown={(e) => e.preventDefault()}
        onClick={() => finish(value, true)}
      >
        <CheckIcon />
      </button>
    </>
  )
}
