import { MAX_ITEM_TITLE } from './api'

/** Typing pause after which a title is sent. */
export const SAVE_DELAY_MS = 700

const unsaved = new Set<symbol>()
// Counts every change ever marked, so a load can tell that one came and went while it ran.
let marks = 0
const waiting: (() => void)[] = []

/** Marks a change as not yet saved on the server; call the returned function once it is (or failed). */
export function markUnsaved(): () => void {
  const token = Symbol()
  unsaved.add(token)
  marks++
  return () => {
    unsaved.delete(token)
    if (unsaved.size === 0) for (const resolve of waiting.splice(0)) resolve()
  }
}

export function hasUnsaved(): boolean {
  return unsaved.size > 0
}

/**
 * Resolves with what `load` got while none of this client's changes were unsaved, from its first request to its
 * answer, so that answer can't be older than them: it waits for them and loads again as often as it takes. Resolves
 * null instead of loading once `current` is false.
 */
export async function loadBetweenWrites<T>(load: () => Promise<T>, current: () => boolean): Promise<T | null> {
  for (;;) {
    while (unsaved.size > 0) await new Promise<void>((resolve) => waiting.push(resolve))
    if (!current()) return null
    const before = marks
    const result = await load()
    if (marks === before) return result
  }
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
