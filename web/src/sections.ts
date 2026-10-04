import type { Category, CategoryOrder, Item } from './api'

export type Section = {
  key: string
  categoryId: number | null
  /** Null when there are no categories, so the one section needs no heading. */
  title: string | null
  open: Item[]
  done: Item[]
}

/**
 * Categories in `order`, with null where Uncategorized goes. Categories the order doesn't know yet
 * (it can lag a fetch behind) go after the known ones, and Uncategorized last if it is missing.
 */
export function arrange(categories: Category[], order: CategoryOrder): (Category | null)[] {
  const byId = new Map(categories.map((c) => [c.id, c]))
  const known = order.flatMap((id) => (id === null ? [null] : byId.has(id) ? [byId.get(id)!] : []))
  const rest: (Category | null)[] = categories.filter((c) => !order.includes(c.id))
  if (!known.includes(null)) rest.push(null)
  return [...known, ...rest]
}

/** One section per entry of the category order, in that order whether or not it has items; `drafts` are left out. */
export function buildSections(
  items: Item[],
  categories: Category[],
  order: CategoryOrder,
  drafts: ReadonlySet<number>,
): Section[] {
  const groups = arrange(categories, order).map((c) =>
    c
      ? { key: `c${c.id}`, categoryId: c.id, title: c.name }
      : { key: 'none', categoryId: null, title: categories.length > 0 ? 'Uncategorized' : null },
  )
  return groups.map((g) => {
    const own = items.filter((i) => i.category_id === g.categoryId && !drafts.has(i.id))
    return { ...g, open: own.filter((i) => !i.checked), done: own.filter((i) => i.checked) }
  })
}

export type Counts = {
  open: number
  done: number
  totalByCategory: Map<number, number>
}

export function countItems(items: Item[]): Counts {
  const totalByCategory = new Map<number, number>()
  let done = 0
  for (const item of items) {
    if (item.category_id !== null) totalByCategory.set(item.category_id, (totalByCategory.get(item.category_id) ?? 0) + 1)
    if (item.checked) done++
  }
  return { open: items.length - done, done, totalByCategory }
}
