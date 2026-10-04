import type { DeletedItem } from './api'

export type DeletedDay = {
  key: string
  label: string
  items: DeletedItem[]
}

// In English on every client, whatever the browser's locale.
const WEEKDAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']
const MONTHS = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
]

/** Groups by the local calendar day of `deleted_at`, newest day first; each group keeps the items' order. */
export function groupByDay(items: DeletedItem[], now: Date): DeletedDay[] {
  const days = new Map<number, DeletedDay>()
  for (const item of items) {
    const at = new Date(item.deleted_at)
    const start = new Date(at.getFullYear(), at.getMonth(), at.getDate()).getTime()
    let day = days.get(start)
    if (!day) {
      day = { key: String(start), label: dayLabel(at, now), items: [] }
      days.set(start, day)
    }
    day.items.push(item)
  }
  return [...days].sort(([a], [b]) => b - a).map(([, day]) => day)
}

/** `item` back where the server lists it, unless it is still there. */
export function putBack(items: DeletedItem[], item: DeletedItem): DeletedItem[] {
  if (items.some((i) => i.id === item.id)) return items
  const at = Date.parse(item.deleted_at)
  const index = items.findIndex((i) => Date.parse(i.deleted_at) < at)
  return index < 0 ? [...items, item] : [...items.slice(0, index), item, ...items.slice(index)]
}

/** `Today`, `Yesterday`, `Monday 28 September`, or `Monday 28 September 2025` outside the current year. */
export function dayLabel(day: Date, now: Date): string {
  if (sameDay(day, now)) return 'Today'
  if (sameDay(day, new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1))) return 'Yesterday'
  const label = `${WEEKDAYS[day.getDay()]} ${day.getDate()} ${MONTHS[day.getMonth()]}`
  return day.getFullYear() === now.getFullYear() ? label : `${label} ${day.getFullYear()}`
}

function sameDay(a: Date, b: Date): boolean {
  return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate()
}
