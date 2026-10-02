import { useState } from 'react'
import { CloseIcon, CopyIcon, KeyIcon } from './icons'
import { QrCode } from './QrCode'
import { TextField } from './TextField'
import { loadToken } from './token'
import { useModal } from './useModal'

type Props = {
  onClose: () => void
}

type CopyState = 'idle' | 'copied' | 'failed'

const withoutTrailingSlashes = (url: string) => url.trim().replace(/\/+$/, '')

function parseHttpUrl(value: string): URL | null {
  if (!URL.canParse(value)) return null
  const url = new URL(value)
  return url.protocol === 'http:' || url.protocol === 'https:' ? url : null
}

const isLoopback = (host: string) =>
  host === 'localhost' || host.endsWith('.localhost') || host.startsWith('127.') || host === '[::1]'

export function ConnectPhone({ onClose }: Props) {
  const ref = useModal()
  const [serverInput, setServerInput] = useState(() => withoutTrailingSlashes(window.location.origin))
  const [copy, setCopy] = useState<CopyState>('idle')

  const server = withoutTrailingSlashes(serverInput)
  const url = parseHttpUrl(server)
  const uri = `checkcheck://connect?server=${encodeURIComponent(server)}&token=${encodeURIComponent(loadToken() ?? '')}`
  // navigator.clipboard only exists in secure contexts, so a plain-http LAN address has no copy button.
  const canCopy = typeof navigator.clipboard?.writeText === 'function'

  let hint = 'An address your phone can reach, without /api.'
  if (!url) hint = 'Enter a full URL, such as https://check.example.com.'
  else if (isLoopback(url.hostname)) hint = "Your phone can't reach localhost. Use this computer's network address."

  async function copyLink() {
    try {
      await navigator.clipboard.writeText(uri)
      setCopy('copied')
    } catch {
      setCopy('failed')
    }
  }

  return (
    <dialog ref={ref} className="dialog dialog-connect" aria-labelledby="connect-title" onClose={onClose}>
      <div className="dialog-head">
        <h2 id="connect-title" className="dialog-title">
          Connect phone
        </h2>
        <button className="icon-btn" type="button" aria-label="Close" onClick={() => ref.current?.close()}>
          <CloseIcon />
        </button>
      </div>
      <p className="dialog-text">Scan this code with the checkcheck app on your phone.</p>

      <TextField
        id="connect-server"
        label="Server URL"
        type="url"
        inputMode="url"
        autoComplete="off"
        autoCapitalize="off"
        spellCheck={false}
        value={serverInput}
        aria-describedby="connect-server-hint"
        aria-invalid={url ? undefined : true}
        onChange={(e) => {
          setServerInput(e.target.value)
          setCopy('idle')
        }}
      />
      <p id="connect-server-hint" className="text-field-support">
        {hint}
      </p>

      <div className="qr-frame">
        {url ? (
          <QrCode value={uri} label="QR code with this server's address and your access token" />
        ) : (
          <p className="qr-placeholder">No code until the server URL is valid.</p>
        )}
      </div>

      <p className="token-warning">
        <KeyIcon />
        This code contains your access token. Only show it to devices you trust.
      </p>

      <div className="dialog-actions">
        {canCopy && url && (
          <button className="btn btn-text" type="button" onClick={() => void copyLink()}>
            <CopyIcon />
            {copy === 'copied' ? 'Copied' : copy === 'failed' ? "Couldn't copy" : 'Copy link'}
          </button>
        )}
        <button className="btn btn-filled" type="button" onClick={() => ref.current?.close()}>
          Done
        </button>
      </div>
    </dialog>
  )
}
