/**
 * Rejects when the browser refuses. Call it straight from the click handler that triggers it, as the
 * plain-http fallback only works during a user gesture.
 */
export async function copyText(text: string, trigger: Element): Promise<void> {
  // navigator.clipboard only exists in secure contexts, which a plain-http LAN address isn't.
  if (navigator.clipboard?.writeText) return navigator.clipboard.writeText(text)

  const area = document.createElement('textarea')
  area.value = text
  // Read-only so iOS doesn't raise the keyboard.
  area.readOnly = true
  area.style.cssText = 'position: fixed; top: 0; left: 0; opacity: 0'
  // Everything outside an open modal is inert and can't be selected.
  const host = trigger.closest('dialog') ?? document.body
  const focused = document.activeElement
  host.append(area)
  area.select()
  // iOS ignores select() on a read-only field.
  area.setSelectionRange(0, text.length)
  try {
    if (!document.execCommand('copy')) throw new Error('Copy refused')
  } finally {
    area.remove()
    if (focused instanceof HTMLElement) focused.focus()
  }
}
