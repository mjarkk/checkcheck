import type { InputHTMLAttributes } from 'react'

type Props = Omit<InputHTMLAttributes<HTMLInputElement>, 'id' | 'placeholder'> & {
  id: string
  label: string
}

export function TextField({ id, label, className, ...input }: Props) {
  return (
    <div className={className ? `text-field ${className}` : 'text-field'}>
      {/* The blank placeholder is what lets CSS float the label via :placeholder-shown. */}
      <input id={id} className="text-field-input" placeholder=" " {...input} />
      <label className="text-field-label" htmlFor={id}>
        {label}
      </label>
    </div>
  )
}
