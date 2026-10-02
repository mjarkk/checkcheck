import { ApiError, type Api, type Preview } from './api'

const FIRST_RETRY_MS = 1000
const MAX_RETRY_MS = 30_000

type Handlers = {
  onPreview: (link: string, preview: Preview) => void
  /** Called on every connect after the first: events sent while disconnected are not replayed. */
  onReconnect: () => void
  onUnauthorized: () => void
}

/** Follows the server's event stream until `signal` aborts, reconnecting with backoff after anything but a 401. */
export async function followEvents(api: Api, signal: AbortSignal, handlers: Handlers) {
  let retryMs = FIRST_RETRY_MS
  let connected = false
  while (!signal.aborted) {
    try {
      const stream = await api.events(signal)
      if (connected) handlers.onReconnect()
      connected = true
      retryMs = FIRST_RETRY_MS
      await readEvents(stream, (type, data) => {
        if (type !== 'preview') return
        const event = JSON.parse(data) as { link: string; preview: Preview }
        handlers.onPreview(event.link, event.preview)
      })
    } catch (err) {
      if (signal.aborted) return
      if (err instanceof ApiError && err.status === 401) {
        handlers.onUnauthorized()
        return
      }
    }
    await sleep(retryMs, signal)
    retryMs = Math.min(retryMs * 2, MAX_RETRY_MS)
  }
}

/** Resolves when the stream ends; `event:` and `data:` fields only. */
async function readEvents(
  stream: ReadableStream<Uint8Array<ArrayBuffer>>,
  dispatch: (type: string, data: string) => void,
) {
  const reader = stream.pipeThrough(new TextDecoderStream()).getReader()
  let pending = ''
  let type = ''
  let data: string[] = []
  for (;;) {
    const { done, value } = await reader.read()
    if (done) return
    const lines = (pending + value).split('\n')
    pending = lines.pop()!
    for (const line of lines.map((l) => l.replace(/\r$/, ''))) {
      if (line === '') {
        if (data.length > 0) dispatch(type || 'message', data.join('\n'))
        type = ''
        data = []
        continue
      }
      if (line.startsWith(':')) continue
      const colon = line.indexOf(':')
      const field = colon < 0 ? line : line.slice(0, colon)
      const fieldValue = colon < 0 ? '' : line.slice(colon + 1).replace(/^ /, '')
      if (field === 'event') type = fieldValue
      else if (field === 'data') data.push(fieldValue)
    }
  }
}

function sleep(ms: number, signal: AbortSignal) {
  return new Promise<void>((resolve) => {
    const timer = setTimeout(resolve, ms)
    signal.addEventListener(
      'abort',
      () => {
        clearTimeout(timer)
        resolve()
      },
      { once: true },
    )
  })
}
