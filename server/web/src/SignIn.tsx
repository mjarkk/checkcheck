import { useState, type FormEvent } from 'react'
import { ApiError, NetworkError, createApi, errorText } from './api'
import { Logo } from './icons'
import { TextField } from './TextField'

type Props = {
  notice: string | null
  onSignedIn: (token: string) => void
}

export function SignIn({ notice, onSignedIn }: Props) {
  const [token, setToken] = useState('')
  const [error, setError] = useState(notice)
  const [busy, setBusy] = useState(false)

  async function submit(e: FormEvent) {
    e.preventDefault()
    const candidate = token.trim()
    if (!candidate || busy) return
    setBusy(true)
    setError(null)
    try {
      await createApi(candidate).listCategories()
      onSignedIn(candidate)
    } catch (err) {
      setError(signInError(err))
      setBusy(false)
    }
  }

  return (
    <main className="signin">
      <form className="signin-card" onSubmit={submit} noValidate>
        <Logo />
        <h1 className="signin-title">checkcheck</h1>
        <p className="signin-text">
          Sign in with the server's token: <code>CHECKCHECK_TOKEN</code>, or the <code>token</code> file in its data
          directory.
        </p>
        <TextField
          id="token"
          label="Token"
          type="password"
          autoComplete="current-password"
          autoFocus
          value={token}
          onChange={(e) => setToken(e.target.value)}
          aria-invalid={error ? true : undefined}
          aria-describedby={error ? 'token-error' : undefined}
        />
        {error && (
          <p id="token-error" className="text-field-support is-error" role="alert">
            {error}
          </p>
        )}
        <button className="btn btn-filled btn-large" type="submit" disabled={busy || !token.trim()}>
          {busy ? 'Checking…' : 'Sign in'}
        </button>
      </form>
    </main>
  )
}

function signInError(err: unknown): string {
  if (err instanceof ApiError && err.status === 401) return 'Token rejected'
  if (err instanceof NetworkError) return "Can't reach the server"
  return errorText(err)
}
