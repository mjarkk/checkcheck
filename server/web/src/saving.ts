import { MAX_ITEM_TITLE } from './api'

/** Typing pause after which a title is sent. */
export const SAVE_DELAY_MS = 700

const unsaved = new Set<symbol>()

/** Marks a change as not yet saved on the server; call the returned function once it is (or failed). */
export function markUnsaved(): () => void {
  const token = Symbol()
  unsaved.add(token)
  return () => {
    unsaved.delete(token)
  }
}

export function hasUnsaved(): boolean {
  return unsaved.size > 0
}

/** Whether an input event pasted or dropped its text in, which arrives whole rather than typed. */
export function isPaste(e: Event): boolean {
  return e instanceof InputEvent && e.inputType.startsWith('insertFrom')
}

/** Line breaks, with the whitespace around them, become one space. */
export function singleLine(text: string): string {
  return text.replace(/\s*[\r\n]+\s*/g, ' ')
}

/** The pasted text's lines, trimmed, without empty ones, each cut to the title limit. */
export function pastedLines(text: string): string[] {
  return text
    .split(/\r\n|\r|\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => line.slice(0, MAX_ITEM_TITLE))
}

/** `lines` without the ones that repeat an earlier line, ignoring case. */
export function withoutDuplicates(lines: string[]): string[] {
  const seen = new Set<string>()
  return lines.filter((line) => {
    const key = line.toLowerCase()
    if (seen.has(key)) return false
    seen.add(key)
    return true
  })
}
