import { useEffect, useState } from 'react'

const PATH = '/deleted'

const atPath = () => location.pathname === PATH

/** Whether the URL is the Recently deleted page, and functions that go there and back to `/`. */
export function useDeletedRoute(): [shown: boolean, open: () => void, close: () => void] {
  const [shown, setShown] = useState(atPath)

  useEffect(() => {
    const onPop = () => setShown(atPath())
    window.addEventListener('popstate', onPop)
    return () => window.removeEventListener('popstate', onPop)
  }, [])

  function open() {
    // Kept in the entry across reloads, so back knows the entry before it is this app's main page.
    history.pushState({ pushed: true }, '', PATH)
    setShown(true)
    window.scrollTo(0, 0)
  }

  function close() {
    if (history.state?.pushed) {
      history.back()
      return
    }
    history.replaceState(null, '', '/')
    setShown(false)
  }

  return [shown, open, close]
}
