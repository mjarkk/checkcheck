import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react'
import { ApiError, type Api, type DeletedItem, type Item } from './api'
import { groupByDay, putBack } from './deleted'
import { ArrowBackIcon, RestoreFromTrashIcon } from './icons'
import { captureScroll, layoutPass, motionRef } from './motion'
import { markUnsaved } from './saving'

type Props = {
  api: Api
  /** Changes whenever the main list reloads to catch up with changes made elsewhere; this list follows. */
  refresh: number
  report: (err: unknown) => void
  onBack: () => void
  onRestored: (item: Item) => void
  onFailed: (err: unknown) => void
  /** A restore found the item no longer restorable, so the main list may be out of date too. */
  onStale: () => void
}

const without = (set: ReadonlySet<number>, id: number) => {
  const next = new Set(set)
  next.delete(id)
  return next
}

export function RecentlyDeleted({ api, refresh, report, onBack, onRestored, onFailed, onStale }: Props) {
  const [items, setItems] = useState<DeletedItem[] | null>(null)
  const [loadFailed, setLoadFailed] = useState(false)
  // What Today and Yesterday are, as of the last load.
  const [now, setNow] = useState(() => new Date())
  const [leaving, setLeaving] = useState<ReadonlySet<number>>(new Set())

  const loadSeq = useRef(0)
  const load = useCallback(async () => {
    const seq = ++loadSeq.current
    try {
      const next = await api.listDeletedItems()
      if (seq !== loadSeq.current) return
      setItems(next)
      setNow(new Date())
      setLoadFailed(false)
    } catch (err) {
      if (seq !== loadSeq.current) return
      setLoadFailed(true)
      report(err)
    }
  }, [api, report])

  useEffect(() => {
    // oxlint-disable-next-line react/set-state-in-effect -- load only sets state after its fetch resolves
    void load()
  }, [load, refresh])

  // Restoring re-renders only this page, so it runs its own layout passes. The first one finds the
  // main page's elements gone, which must not fade out over this one.
  const entered = useRef(false)
  captureScroll()
  useLayoutEffect(() => {
    layoutPass(entered.current)
    entered.current = true
  })

  async function restore(item: DeletedItem) {
    setLeaving((prev) => new Set(prev).add(item.id))
    const saved = markUnsaved()
    try {
      onRestored(await api.restoreItem(item.id))
    } catch (err) {
      if (err instanceof ApiError && err.status === 404) {
        void load()
        onStale()
        return
      }
      setLeaving((prev) => without(prev, item.id))
      setItems((prev) => prev && putBack(prev, item))
      onFailed(err)
    } finally {
      saved()
    }
  }

  function removeRow(id: number) {
    setItems((prev) => prev && prev.filter((i) => i.id !== id))
    setLeaving((prev) => without(prev, id))
  }

  const days = items && groupByDay(items, now)

  return (
    <>
      <div className="page-head">
        <button className="icon-btn" type="button" aria-label="Back" title="Back" onClick={onBack}>
          <ArrowBackIcon />
        </button>
        <h1 className="page-title">Recently deleted</h1>
      </div>
      <div className="summary">
        <p>Deleted items are kept for 30 days</p>
      </div>
      {days === null ? (
        loadFailed ? (
          <div className="empty">
            <p>Couldn't load recently deleted items.</p>
            <button className="btn btn-tonal" type="button" onClick={() => void load()}>
              Try again
            </button>
          </div>
        ) : (
          <p className="empty" role="status">
            Loading…
          </p>
        )
      ) : days.length === 0 ? (
        <p className="empty deleted-empty">Nothing deleted in the last 30 days</p>
      ) : (
        days.map((day) => {
          const headLeaving = day.items.every((i) => leaving.has(i.id))
          return (
            <section key={day.key} className="section" aria-labelledby={`deleted-day-${day.key}`}>
              <div
                ref={motionRef(`deleted-day:${day.key}`)}
                className={headLeaving ? 'list-head section-head is-leaving' : 'list-head section-head'}
                data-no-ghost={headLeaving || undefined}
              >
                <h2 id={`deleted-day-${day.key}`} className="section-title">
                  {day.label}
                </h2>
              </div>
              <ul className="list">
                {day.items.map((item) => (
                  <DeletedRow
                    key={item.id}
                    item={item}
                    leaving={leaving.has(item.id)}
                    onRestore={() => void restore(item)}
                    onLeft={() => removeRow(item.id)}
                  />
                ))}
              </ul>
            </section>
          )
        })
      )}
    </>
  )
}

type RowProps = {
  item: DeletedItem
  leaving: boolean
  onRestore: () => void
  onLeft: () => void
}

function DeletedRow({ item, leaving, onRestore, onLeft }: RowProps) {
  let className = 'item deleted-row'
  if (item.checked) className += ' is-checked'
  if (leaving) className += ' is-leaving'

  return (
    <li
      ref={motionRef(`deleted:${item.id}`)}
      className={className}
      data-no-ghost={leaving || undefined}
      inert={leaving}
      onAnimationEnd={(e) => {
        if (leaving && e.target === e.currentTarget) onLeft()
      }}
    >
      {/* The main rows' title look, read-only. */}
      <span className="title-input">{item.title}</span>
      <button
        className="icon-btn deleted-restore"
        type="button"
        aria-label={`Restore ${item.title}`}
        title="Restore"
        onClick={onRestore}
      >
        <RestoreFromTrashIcon />
      </button>
    </li>
  )
}
