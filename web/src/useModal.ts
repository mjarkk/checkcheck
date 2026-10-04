import { useEffect, useRef } from 'react'

/**
 * Opens the referenced <dialog> as a modal once it mounts. Close it with `dialog.close()` (or a
 * `<form method="dialog">`) and unmount it from its `onClose`, so the browser restores focus.
 */
export function useModal() {
  const ref = useRef<HTMLDialogElement>(null)
  useEffect(() => {
    const dialog = ref.current
    if (dialog && !dialog.open) dialog.showModal()
  }, [])
  return ref
}
