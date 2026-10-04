import { useState, type ChangeEvent, type FormEvent } from 'react'
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

  async function signIn(value: string) {
    const candidate = value.trim()
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

  function submit(e: FormEvent) {
    e.preventDefault()
    signIn(token)
  }

  function change(e: ChangeEvent<HTMLInputElement>) {
    setToken(e.target.value)
    if ((e.nativeEvent as InputEvent).inputType === 'insertFromPaste') signIn(e.target.value)
  }

  return (
    <main className="signin">
      <form className="signin-card" onSubmit={submit} noValidate>
        <Logo />
        <h1 className="signin-title">CheckCheck</h1>
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
          onChange={change}
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
