import type { KeyboardEvent } from 'react'

/** The title fields in `field`'s list that can take focus, in order, `field` included. */
function linesAround(field: HTMLTextAreaElement): HTMLTextAreaElement[] {
  const lines = [...(field.closest('.list')?.querySelectorAll<HTMLTextAreaElement>('.title-input') ?? [])]
  return lines.filter((line) => line === field || !line.closest('[inert]'))
}

export function lineAbove(field: HTMLTextAreaElement): HTMLTextAreaElement | undefined {
  const lines = linesAround(field)
  return lines[lines.indexOf(field) - 1]
}

export function lineBelow(field: HTMLTextAreaElement): HTMLTextAreaElement | undefined {
  const lines = linesAround(field)
  return lines[lines.indexOf(field) + 1]
}

export function focusEnd(line: HTMLTextAreaElement) {
  line.focus()
  line.setSelectionRange(line.value.length, line.value.length)
}

/** ArrowUp at the start of the field or ArrowDown at its end, or either with all its text selected, focuses the line that way. */
export function arrowToLine(e: KeyboardEvent<HTMLTextAreaElement>) {
  if (e.shiftKey || e.altKey || e.ctrlKey || e.metaKey) return
  const field = e.currentTarget
  const { selectionStart: start, selectionEnd: end, value } = field
  const all = start === 0 && end === value.length
  // The caret lands on the edge it left from, so holding the key walks the list a line at a time.
  if (e.key === 'ArrowUp' && (end === 0 || all)) {
    const above = lineAbove(field)
    if (!above) return
    e.preventDefault()
    above.focus()
    above.setSelectionRange(0, 0)
  } else if (e.key === 'ArrowDown' && (start === value.length || all)) {
    const below = lineBelow(field)
    if (!below) return
    e.preventDefault()
    focusEnd(below)
  }
}
