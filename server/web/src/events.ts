import { CLIENT_ID, type Api, type Preview } from './api'

const FIRST_RETRY_MS = 1000
const MAX_RETRY_MS = 30_000
// The server pings every 15 s, so a socket this quiet is dead.
const SILENCE_MS = 40_000
// Move all to… sends one changed per item.
const SETTLE_MS = 300
const UNAUTHORIZED = 4401

type Handlers = {
  onPreview: (link: string, preview: Preview) => void
  /**
   * The lists may have changed without this client: on every `ready`, the first included, because events are not
   * replayed, and once another client's changes have stopped coming for a moment.
   */
  onCatchUp: () => void
  onUnauthorized: () => void
}

type ServerEvent =
  | { type: 'ready' | 'ping' }
  | { type: 'changed'; client?: string }
  | { type: 'preview'; link: string; preview: Preview }

/** Follows the server's live updates until `signal` aborts, reconnecting with backoff after anything but a 4401. */
export function followEvents(api: Api, signal: AbortSignal, handlers: Handlers) {
  let socket: WebSocket
  let retryMs = FIRST_RETRY_MS
  let retry: number | undefined
  let silence: number | undefined
  let settle: number | undefined

  function connect() {
    socket = api.events()
    socket.onmessage = (e) => {
      watchSilence()
      const event = JSON.parse(e.data as string) as ServerEvent
      if (event.type === 'ready') {
        retryMs = FIRST_RETRY_MS
        clearTimeout(settle)
        handlers.onCatchUp()
      } else if (event.type === 'changed' && event.client !== CLIENT_ID) {
        clearTimeout(settle)
        settle = window.setTimeout(handlers.onCatchUp, SETTLE_MS)
      } else if (event.type === 'preview') {
        handlers.onPreview(event.link, event.preview)
      }
    }
    socket.onclose = (e) => {
      clearTimeout(silence)
      if (e.code === UNAUTHORIZED) handlers.onUnauthorized()
      else reconnect()
    }
    watchSilence()
  }

  function watchSilence() {
    clearTimeout(silence)
    silence = window.setTimeout(() => {
      // A dead connection can take long to report its close, so this doesn't wait for it.
      close()
      reconnect()
    }, SILENCE_MS)
  }

  function reconnect() {
    retry = window.setTimeout(connect, retryMs)
    retryMs = Math.min(retryMs * 2, MAX_RETRY_MS)
  }

  function close() {
    socket.onmessage = null
    socket.onclose = null
    socket.close()
  }

  connect()
  signal.addEventListener(
    'abort',
    () => {
      clearTimeout(retry)
      clearTimeout(silence)
      clearTimeout(settle)
      close()
    },
    { once: true },
  )
}
