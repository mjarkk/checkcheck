import { useCallback, useState } from 'react'
import { Checklist } from './Checklist'
import { SignIn } from './SignIn'
import { clearToken, loadToken, saveToken } from './token'

export function App() {
  const [token, setToken] = useState(loadToken)
  const [notice, setNotice] = useState<string | null>(null)

  const signIn = useCallback((next: string) => {
    saveToken(next)
    setNotice(null)
    setToken(next)
  }, [])

  const signOut = useCallback((reason: string | null) => {
    clearToken()
    setNotice(reason)
    setToken(null)
  }, [])

  const onSignOut = useCallback(() => signOut(null), [signOut])
  const onUnauthorized = useCallback(() => signOut('Token rejected. Sign in again.'), [signOut])

  if (!token) return <SignIn notice={notice} onSignedIn={signIn} />
  return <Checklist token={token} onSignOut={onSignOut} onUnauthorized={onUnauthorized} />
}
