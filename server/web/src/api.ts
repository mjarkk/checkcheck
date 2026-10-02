export type Category = {
  id: number
  name: string
  created_at: string
  updated_at: string
}

export type Item = {
  id: number
  title: string
  checked: boolean
  category_id: number | null
  /** The first http(s) URL in the title. */
  link: string | null
  /** Null until the server has fetched `link`, and when it found nothing there. */
  preview: Preview | null
  created_at: string
  updated_at: string
}

/** An item in Recently deleted, as it was when it was deleted. */
export type DeletedItem = Pick<Item, 'id' | 'title' | 'checked' | 'created_at' | 'updated_at'> & {
  deleted_at: string
}

/** What the server found at a link; it has at least one of `title`, `description` and `image`. */
export type Preview = {
  title?: string
  description?: string
  image?: string
  site_name?: string
  icon?: string
}

export type ItemPatch = Partial<Pick<Item, 'title' | 'checked' | 'category_id'>> & {
  /** Moves the item directly before this one in the list order; null moves it to the end. */
  before_id?: number | null
}

/** Every category id once, in the user's order, plus one null where Uncategorized goes. */
export type CategoryOrder = (number | null)[]

export const MAX_CATEGORY_NAME = 100
export const MAX_ITEM_TITLE = 500

export class ApiError extends Error {
  readonly status: number

  constructor(status: number, message: string) {
    super(message)
    this.name = 'ApiError'
    this.status = status
  }
}

export class NetworkError extends Error {
  constructor() {
    super("Can't reach the server")
    this.name = 'NetworkError'
  }
}

// What a proxy in front of the server answers while the server is down; Vite's dev proxy sends 502.
const GATEWAY_STATUSES = new Set([502, 503, 504])

/** Made once per page load; the server names it in the `changed` events of this page's own writes. */
export const CLIENT_ID = Array.from(
  // Not crypto.randomUUID(): that only exists in secure contexts, and the server is often plain http on the LAN.
  crypto.getRandomValues(new Uint8Array(16)),
  (b) => b.toString(16).padStart(2, '0'),
).join('')

export type Api = ReturnType<typeof createApi>

/** Every call rejects with NetworkError when the server is unreachable and ApiError on any other non-2xx. */
export function createApi(token: string) {
  async function request<T>(method: string, path: string, body?: unknown): Promise<T> {
    const headers: Record<string, string> = {
      Authorization: `Bearer ${token}`,
      Accept: 'application/json',
      'X-Checkcheck-Client': CLIENT_ID,
    }
    if (body !== undefined) headers['Content-Type'] = 'application/json'

    let res: Response
    try {
      res = await fetch(path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) })
    } catch {
      throw new NetworkError()
    }
    if (GATEWAY_STATUSES.has(res.status)) throw new NetworkError()
    if (!res.ok) throw new ApiError(res.status, await readError(res))
    if (res.status === 204) return undefined as T
    return (await res.json()) as T
  }

  return {
    listCategories: () => request<Category[]>('GET', '/api/categories'),
    createCategory: (name: string) => request<Category>('POST', '/api/categories', { name }),
    renameCategory: (id: number, name: string) => request<Category>('PATCH', `/api/categories/${id}`, { name }),
    deleteCategory: (id: number) => request<void>('DELETE', `/api/categories/${id}`),
    categoryOrder: () => request<{ order: CategoryOrder }>('GET', '/api/categories/order').then((r) => r.order),
    setCategoryOrder: (order: CategoryOrder) =>
      request<{ order: CategoryOrder }>('PUT', '/api/categories/order', { order }).then((r) => r.order),
    listItems: () => request<Item[]>('GET', '/api/items'),
    createItem: (title: string, categoryId: number | null) =>
      request<Item>('POST', '/api/items', { title, category_id: categoryId }),
    updateItem: (id: number, patch: ItemPatch) => request<Item>('PATCH', `/api/items/${id}`, patch),
    deleteItem: (id: number) => request<void>('DELETE', `/api/items/${id}`),
    /** Most recently deleted first. */
    listDeletedItems: () => request<DeletedItem[]>('GET', '/api/items/deleted'),
    /** Back into Uncategorized, at the end of the list order. */
    restoreItem: (id: number) => request<Item>('POST', `/api/items/${id}/restore`),
    /** A new live updates socket, which signs in as soon as it opens. */
    events: () => {
      const url = new URL('/api/events', location.href)
      url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:'
      const socket = new WebSocket(url)
      socket.onopen = () => socket.send(JSON.stringify({ type: 'auth', token, client: CLIENT_ID }))
      return socket
    },
  }
}

async function readError(res: Response): Promise<string> {
  const body: unknown = await res.json().catch(() => null)
  if (body && typeof body === 'object' && 'error' in body && typeof body.error === 'string') return body.error
  return `Request failed (${res.status})`
}

export function errorText(err: unknown): string {
  return err instanceof Error ? err.message : 'Something went wrong'
}
