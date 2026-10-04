import { useEffect, useState } from 'react'
import { copyText } from './clipboard'
import { CheckIcon, CloseIcon, CopyIcon, KeyIcon } from './icons'
import { loadToken } from './token'
import { useModal } from './useModal'

type Props = {
  onClose: () => void
}

const CLIENTS = ['Claude', 'Claude Code', 'Other'] as const

type Client = (typeof CLIENTS)[number]

const COPIED_MS = 2000

// Pinned to the release these steps were tested with.
const MCP_REMOTE_VERSION = '0.14.3'

export function ConnectAssistant({ onClose }: Props) {
  const ref = useModal()
  const [client, setClient] = useState<Client>('Claude')
  const token = loadToken() ?? ''
  const url = `${window.location.origin}/mcp`
  const steps = { url, token, tokenUrl: `${url}/${encodeURIComponent(token)}` }

  return (
    <dialog ref={ref} className="dialog dialog-assistant" aria-labelledby="assistant-title" onClose={onClose}>
      <div className="dialog-head">
        <h2 id="assistant-title" className="dialog-title">
          Connect AI
        </h2>
        <button className="icon-btn" type="button" aria-label="Close" onClick={() => ref.current?.close()}>
          <CloseIcon />
        </button>
      </div>
      <p className="dialog-text">Let Claude or another AI app read and update your checklist over MCP.</p>

      <div className="client-picker" role="group" aria-label="App">
        {CLIENTS.map((c) => (
          <button
            key={c}
            className="client-option"
            type="button"
            aria-pressed={c === client}
            onClick={() => setClient(c)}
          >
            {c}
          </button>
        ))}
      </div>

      {/* Keyed so switching apps starts the panel scrolled to the top. */}
      <div key={client} className="assistant-panel">
        {client === 'Claude' && <ClaudeSteps {...steps} />}
        {client === 'Claude Code' && <CodeSteps {...steps} />}
        {client === 'Other' && <OtherSteps {...steps} />}

        <p className="token-warning">
          <KeyIcon />
          These contain your access token. Only paste them into apps you trust.
        </p>
      </div>

      <div className="dialog-actions">
        <button className="btn btn-filled" type="button" onClick={() => ref.current?.close()}>
          Done
        </button>
      </div>
    </dialog>
  )
}

type StepsProps = {
  url: string
  token: string
  tokenUrl: string
}

function ClaudeSteps({ url, token, tokenUrl }: StepsProps) {
  return (
    <>
      <p className="steps-intro">
        For Claude on the web, on your computer and on your phone. Claude connects from Anthropic's cloud, so this
        server needs a public HTTPS address.
        {window.location.protocol === 'http:' && " This page is plain http, so use your server's https:// address."}
      </p>
      <ol className="steps">
        <li>
          On <a href="https://claude.ai/customize/connectors">claude.ai</a> or in Claude Desktop, open{' '}
          <strong>Customize → Connectors</strong> and click <strong>Add custom connector</strong>.
        </li>
        <li>
          Name it CheckCheck, paste this URL and leave authentication on <strong>No sign-in</strong>. The token is
          part of the URL.
          <Snippet label="Connector URL" code={tokenUrl} />
        </li>
        <li>
          Click <strong>Add</strong>. CheckCheck now also works in the Claude app on your phone. Turn it on in a chat
          under <strong>+ → Connectors</strong>.
        </li>
      </ol>

      <h3 className="steps-heading">Server not on the internet?</h3>
      <p className="steps-intro">
        Claude Desktop can still connect from your own computer, through the <code>mcp-remote</code> bridge.
      </p>
      <DesktopSteps url={url} token={token} />
    </>
  )
}

function DesktopSteps({ url, token }: Pick<StepsProps, 'url' | 'token'>) {
  return (
    <ol className="steps">
      <li>
        Install <a href="https://nodejs.org">Node.js</a> 18 or newer if you don't have it. Claude Desktop reaches
        CheckCheck through the <code>mcp-remote</code> bridge, which runs with <code>npx</code>.
      </li>
      <li>
        In Claude Desktop, open <strong>Settings → Developer → Edit Config</strong>.
      </li>
      <li>
        Paste this into <code>claude_desktop_config.json</code>. If the file already has <code>mcpServers</code>, add
        just the <code>checkcheck</code> entry to it.
        <Snippet label="claude_desktop_config.json" code={desktopConfig(url, token)} wrap={false} />
      </li>
      <li>
        Quit Claude Desktop completely and open it again. If CheckCheck fails to start, set <code>command</code> to the
        full path of <code>npx</code>.
      </li>
    </ol>
  )
}

function CodeSteps({ url, token }: StepsProps) {
  return (
    <ol className="steps">
      <li>
        Run this in a terminal. <code>--scope user</code> makes CheckCheck available in all your projects.
        <Snippet
          label="Terminal"
          code={`claude mcp add --transport http --scope user checkcheck ${url} --header "Authorization: Bearer ${token}"`}
        />
      </li>
      <li>
        Start Claude Code and run <code>/mcp</code> to check that CheckCheck is connected.
      </li>
    </ol>
  )
}

function OtherSteps({ url, token, tokenUrl }: StepsProps) {
  return (
    <div className="steps-plain">
      <p>
        Apps that connect to remote MCP servers over Streamable HTTP with a custom header, such as Cursor, VS Code,
        Codex and Gemini CLI, need these two values:
      </p>
      <Snippet label="Server URL" code={url} />
      <Snippet label="Header" code={`Authorization: Bearer ${token}`} />
      <p>Apps that can't set a header, such as ChatGPT, can use this URL with the token in it instead:</p>
      <Snippet label="URL with token" code={tokenUrl} />
      <p className="steps-note">
        Apps that run in the cloud need a public HTTPS address. Apps that only run local servers can use{' '}
        <code>mcp-remote</code> as in the Claude tab.
      </p>
    </div>
  )
}

function desktopConfig(url: string, token: string): string {
  // Claude Desktop on Windows splits args on spaces, so the header's value comes from env, which mcp-remote expands.
  const args = ['-y', `mcp-remote@${MCP_REMOTE_VERSION}`, url, '--header', 'Authorization:${AUTH_HEADER}']
  // mcp-remote refuses plain http to anything but localhost unless told otherwise.
  if (url.startsWith('http:')) args.push('--allow-http')
  const config = { mcpServers: { checkcheck: { command: 'npx', args, env: { AUTH_HEADER: `Bearer ${token}` } } } }
  return JSON.stringify(config, null, 2)
}

type SnippetProps = {
  label: string
  code: string
  wrap?: boolean
}

function Snippet({ label, code, wrap = true }: SnippetProps) {
  const [copy, setCopy] = useState<'idle' | 'copied' | 'failed'>('idle')

  useEffect(() => {
    if (copy === 'idle') return
    const timer = setTimeout(() => setCopy('idle'), COPIED_MS)
    return () => clearTimeout(timer)
  }, [copy])

  async function copyCode(trigger: Element) {
    try {
      await copyText(code, trigger)
      setCopy('copied')
    } catch {
      setCopy('failed')
    }
  }

  return (
    <figure className="snippet">
      <figcaption className="snippet-head">
        <span className="snippet-label">{label}</span>
        <button className="btn btn-text snippet-copy" type="button" onClick={(e) => void copyCode(e.currentTarget)}>
          {copy === 'copied' ? <CheckIcon /> : <CopyIcon />}
          {copy === 'copied' ? 'Copied' : copy === 'failed' ? "Couldn't copy" : 'Copy'}
        </button>
      </figcaption>
      <pre className={wrap ? 'snippet-code' : 'snippet-code is-nowrap'}>
        <code>{code}</code>
      </pre>
    </figure>
  )
}
