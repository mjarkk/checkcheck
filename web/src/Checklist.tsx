import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { flushSync } from 'react-dom'
import { AddItemLine } from './AddItemLine'
import { AddItems } from './AddItems'
import {
  ApiError,
  createApi,
  errorText,
  type Category,
  type CategoryOrder,
  type Item,
  type ItemPatch,
  type Preview,
} from './api'
import { CategoryManager } from './CategoryManager'
import { ConfirmDialog } from './ConfirmDialog'
import { ConnectAssistant } from './ConnectAssistant'
import { ConnectPhone } from './ConnectPhone'
import { NEW_CATEGORY_ZONE, useListDrag, withGap, type DropTarget } from './drag'
import { ErrorNotice } from './ErrorNotice'
import { followEvents } from './events'
import { ItemRow } from './ItemRow'
import {
  AutoDeleteIcon,
  DeleteSweepIcon,
  DoneAllIcon,
  DriveFileMoveIcon,
  LabelIcon,
  Logo,
  LogoutIcon,
  NewLabelIcon,
  QrIcon,
  RemoveDoneIcon,
  SparkleIcon,
} from './icons'
import { MoreMenu } from './MoreMenu'
import { MoveItemsDialog } from './MoveItemsDialog'
import { captureScroll, inheritMotion, layoutPass, motionRef, prepareLayoutPass } from './motion'
import { NewCategoryDialog } from './NewCategoryDialog'
import { RecentlyDeleted } from './RecentlyDeleted'
import { hasUnsaved, loadBetweenWrites, markUnsaved } from './saving'
import { buildSections, countItems, type Section } from './sections'
import { useDeletedRoute } from './useDeletedRoute'
import { usePasteRoute, type PasteTarget } from './usePasteRoute'

type Props = {
  token: string
  onSignOut: () => void
  onUnauthorized: () => void
}

type Notice = { id: number; message: string }

/** An item dropped on the new-category circle, at viewport point `from`, waiting for the category's name. */
type Parked = { id: number; from: { x: number; y: number } }

/** A Delete all that includes items not done yet, waiting for confirmation. */
type PendingClear = { ids: number[]; title: string; message: string }

const NOTICE_MS = 6000

let noticeSeq = 0

const isUnauthorized = (err: unknown) => err instanceof ApiError && err.status === 401

const conflictMessage = (err: unknown) =>
  err instanceof ApiError && err.status === 409 ? 'A category with that name already exists' : undefined

const without = (set: ReadonlySet<number>, id: number) => {
  const next = new Set(set)
  next.delete(id)
  return next
}

export function Checklist({ token, onSignOut, onUnauthorized }: Props) {
  const api = useMemo(() => createApi(token), [token])
  const [categories, setCategories] = useState<Category[]>([])
  const [categoryOrder, setCategoryOrder] = useState<CategoryOrder>([])
  const [items, setItems] = useState<Item[] | null>(null)
  const [loadFailed, setLoadFailed] = useState(false)
  const [leaving, setLeaving] = useState<ReadonlySet<number>>(new Set())
  // Created from an Add item line that is still being typed in: the line shows them, the list doesn't.
  const [drafts, setDrafts] = useState<ReadonlySet<number>>(new Set())
  // By link rather than on the items: an event can arrive before the response that gives an item its link.
  const [previews, setPreviews] = useState<ReadonlyMap<string, Preview>>(new Map())
  // Kept here, not in the rows: only a commit of this component springs the rows below.
  const [expandedPreviews, setExpandedPreviews] = useState<ReadonlySet<number>>(new Set())
  const [brokenImages, setBrokenImages] = useState<ReadonlySet<string>>(new Set())
  const [managing, setManaging] = useState(false)
  const [connecting, setConnecting] = useState(false)
  const [connectingAssistant, setConnectingAssistant] = useState(false)
  const [confirmingSignOut, setConfirmingSignOut] = useState(false)
  const [notice, setNotice] = useState<Notice | null>(null)
  const [parked, setParked] = useState<Parked | null>(null)
  const [pendingClear, setPendingClear] = useState<PendingClear | null>(null)
  // The key of the section whose Move all to… dialog is open.
  const [movingFrom, setMovingFrom] = useState<string | null>(null)
  const parkedCategory = useRef<{ id: number; categories?: Category[]; order?: CategoryOrder } | null>(null)
  const newCategoryDrop = useRef<HTMLDivElement>(null)
  const main = useRef<HTMLElement>(null)
  const [deletedShown, openDeleted, closeDeleted] = useDeletedRoute()
  const [paste, openPaste, choosePasted, closePaste] = usePasteRoute()
  // Counts the catch-up reloads below, which Recently deleted follows with its own list.
  const [catchUps, setCatchUps] = useState(0)

  const report = useCallback(
    (err: unknown, message?: string) => {
      if (isUnauthorized(err)) onUnauthorized()
      else setNotice({ id: ++noticeSeq, message: message ?? errorText(err) })
    },
    [onUnauthorized],
  )

  // A reload during a drag would move rows out from under it, so it waits for the drop.
  const dragging = useRef(false)
  const reloadAfterDrag = useRef(false)

  const loadSeq = useRef(0)
  const reload = useCallback(async () => {
    if (dragging.current) {
      reloadAfterDrag.current = true
      return
    }
    const seq = ++loadSeq.current
    try {
      const loaded = await loadBetweenWrites(
        () => Promise.all([api.listCategories(), api.categoryOrder(), api.listItems()]),
        () => seq === loadSeq.current,
      )
      if (!loaded || seq !== loadSeq.current) return
      if (dragging.current) {
        reloadAfterDrag.current = true
        return
      }
      const [nextCategories, nextOrder, nextItems] = loaded
      setCategories(nextCategories)
      setCategoryOrder(nextOrder)
      setItems(nextItems)
      setPreviews((prev) => withPreviews(prev, nextItems))
      setLoadFailed(false)
    } catch (err) {
      if (seq !== loadSeq.current) return
      setLoadFailed(true)
      report(err)
    }
  }, [api, report])

  useEffect(() => {
    // oxlint-disable-next-line react/set-state-in-effect -- reload only sets state after its fetch resolves
    void reload()
    // A background tab's socket can be dead without knowing it yet, and behind a proxy that doesn't pass WebSocket
    // upgrades there is none, so catch up whenever the tab comes back too.
    const onVisible = () => {
      if (document.visibilityState !== 'visible') return
      void reload()
      setCatchUps((n) => n + 1)
    }
    document.addEventListener('visibilitychange', onVisible)
    return () => document.removeEventListener('visibilitychange', onVisible)
  }, [reload])

  useEffect(() => {
    const stop = new AbortController()
    followEvents(api, stop.signal, {
      onPreview: (link, preview) => setPreviews((prev) => new Map(prev).set(link, preview)),
      onCatchUp: () => {
        void reload()
        setCatchUps((n) => n + 1)
      },
      onUnauthorized,
    })
    return () => stop.abort()
  }, [api, reload, onUnauthorized])

  useEffect(() => {
    if (!notice) return
    const timer = setTimeout(() => setNotice(null), NOTICE_MS)
    return () => clearTimeout(timer)
  }, [notice])

  useEffect(() => {
    const warn = (e: BeforeUnloadEvent) => {
      if (!hasUnsaved()) return
      e.preventDefault()
      // Older Safari only asks when returnValue is set.
      e.returnValue = ''
    }
    window.addEventListener('beforeunload', warn)
    return () => window.removeEventListener('beforeunload', warn)
  }, [])

  captureScroll()
  // A page switch replaces everything in main: the new page plays its enter animations, and the old
  // one must not fade out over it.
  const page = deletedShown ? 'deleted' : paste ? 'add' : 'list'
  const passedPage = useRef(page)
  useLayoutEffect(() => {
    layoutPass(passedPage.current === page)
    passedPage.current = page
  })
  useEffect(() => {
    // Text wrapping differently (typing, resizing, fonts loading) moves rows without a render here.
    const observer = new ResizeObserver(() => layoutPass(false))
    observer.observe(main.current!)
    return () => observer.disconnect()
  }, [])

  function failed(err: unknown, message?: string) {
    report(err, message)
    if (!isUnauthorized(err)) void reload()
  }

  async function createItem(title: string, categoryId: number | null): Promise<Item | null> {
    const saved = markUnsaved()
    try {
      const item = await api.createItem(title, categoryId)
      setDrafts((prev) => new Set(prev).add(item.id))
      setItems((prev) => [...(prev ?? []), item])
      setPreviews((prev) => withPreviews(prev, [item]))
      return item
    } catch (err) {
      failed(err)
      return null
    } finally {
      saved()
    }
  }

  function releaseDraft(id: number, sectionKey: string) {
    inheritMotion(`add:${sectionKey}`, `item:${id}`)
    setDrafts((prev) => without(prev, id))
  }

  async function discardDraft(id: number) {
    const saved = markUnsaved()
    try {
      await itemWrites.current.get(id)
      await api.deleteItem(id)
      setItems((prev) => prev && prev.filter((i) => i.id !== id))
    } catch (err) {
      failed(err)
    } finally {
      setDrafts((prev) => without(prev, id))
      saved()
    }
  }

  // Serialized per item so the server applies writes in click order. Only the newest response is
  // applied: the optimistic state already holds every queued patch, so an older one would flicker back.
  const itemWrites = useRef(new Map<number, Promise<unknown>>())

  /** Resolves with the error instead of reporting it, so a batch reports once. Waits for the write `after` too. */
  function writePatch(id: number, patch: ItemPatch, after?: Promise<unknown>): Promise<unknown> {
    const write: Promise<unknown> = Promise.all([itemWrites.current.get(id), after])
      .then(() => api.updateItem(id, patch))
      .then(
        (updated) => {
          setPreviews((prev) => withPreviews(prev, [updated]))
          if (itemWrites.current.get(id) !== write) return
          itemWrites.current.delete(id)
          setItems((prev) => prev && prev.map((i) => (i.id === id ? updated : i)))
        },
        (err: unknown) => {
          if (itemWrites.current.get(id) === write) itemWrites.current.delete(id)
          return err
        },
      )
      .finally(markUnsaved())
    itemWrites.current.set(id, write)
    return write
  }

  /** `inOrder` sends each write only once the one before it is done. */
  function patchItems(ids: number[], patch: ItemPatch, inOrder = false) {
    setItems((prev) => prev && ids.reduce((next, id) => applyPatch(next, id, patch), prev))
    let previous: Promise<unknown> | undefined
    const writes = ids.map((id) => (previous = writePatch(id, patch, inOrder ? previous : undefined)))
    void Promise.all(writes).then((errors) => {
      const err = errors.find((e) => e !== undefined)
      if (err !== undefined) failed(err)
    })
  }

  function patchItem(id: number, patch: ItemPatch) {
    patchItems([id], patch)
  }

  function markLeaving(ids: number[], isLeaving: boolean) {
    setLeaving((prev) => {
      const next = new Set(prev)
      for (const id of ids) {
        if (isLeaving) next.add(id)
        else next.delete(id)
      }
      return next
    })
  }

  async function deleteItems(ids: number[]) {
    markLeaving(ids, true)
    const saved = markUnsaved()
    const results = await Promise.allSettled(
      ids.map(async (id) => {
        await itemWrites.current.get(id)
        await api.deleteItem(id)
      }),
    )
    saved()
    const rejected = results.find((r) => r.status === 'rejected')
    if (!rejected) return
    markLeaving(
      ids.filter((_, i) => results[i].status === 'rejected'),
      false,
    )
    failed(rejected.reason)
  }

  function removeItem(id: number) {
    setItems((prev) => prev && prev.filter((i) => i.id !== id))
    markLeaving([id], false)
  }

  function addRestored(item: Item) {
    setItems((prev) => prev && [...prev, item])
    setPreviews((prev) => withPreviews(prev, [item]))
  }

  function deleteAll(rows: Item[], sectionTitle: string | null) {
    const ids = rows.map((i) => i.id)
    const open = rows.filter((i) => !i.checked).length
    if (open === 0) {
      void deleteItems(ids)
      return
    }
    setPendingClear({
      ids,
      title: sectionTitle ? `Delete all items in “${sectionTitle}”?` : 'Delete all items?',
      message: notDoneMessage(open, ids.length),
    })
  }

  function confirmClear(ids: number[]) {
    setPendingClear(null)
    const still = ids.filter((id) => !leaving.has(id) && items?.some((i) => i.id === id))
    if (still.length > 0) void deleteItems(still)
  }

  async function addLines(lines: string[], target: PasteTarget) {
    let categoryId: number | null
    const patch: ItemPatch = {}
    if ('section' in target) {
      categoryId = target.section.categoryId
    } else {
      const list = items ?? []
      const at = list.findIndex((i) => i.id === target.item.id)
      // Once the item is gone, the end of the list it was in.
      const anchor = at < 0 ? target.item : { categoryId: list[at].category_id, checked: list[at].checked }
      categoryId = anchor.categoryId
      if (at >= 0) patch.before_id = list[at + 1]?.id ?? null
      if (anchor.checked) patch.checked = true
    }
    const saved = markUnsaved()
    try {
      // One at a time, so the server appends them in the lines' order.
      for (const title of lines) {
        const item = await api.createItem(title, categoryId)
        setItems((prev) => [...(prev ?? []), item])
        setPreviews((prev) => withPreviews(prev, [item]))
        if (Object.keys(patch).length > 0) patchItem(item.id, patch)
      }
    } catch (err) {
      failed(err)
    } finally {
      saved()
    }
  }

  async function createCategory(name: string): Promise<boolean> {
    try {
      await api.createCategory(name)
      await reload()
      return true
    } catch (err) {
      failed(err, conflictMessage(err))
      return false
    }
  }

  async function renameCategory(id: number, name: string): Promise<boolean> {
    try {
      await api.renameCategory(id, name)
      await reload()
      return true
    } catch (err) {
      failed(err, conflictMessage(err))
      return false
    }
  }

  async function reorderCategories(order: CategoryOrder) {
    setCategoryOrder(order)
    const saved = markUnsaved()
    try {
      await api.setCategoryOrder(order)
    } catch (err) {
      failed(err)
    } finally {
      saved()
    }
  }

  async function deleteCategory(id: number) {
    try {
      await api.deleteCategory(id)
      await reload()
    } catch (err) {
      failed(err)
    }
  }

  const counts = useMemo(() => countItems(items ?? []), [items])
  const sections = useMemo(
    () => buildSections(items ?? [], categories, categoryOrder, drafts),
    [items, categories, categoryOrder, drafts],
  )
  const movingSection = sections.find((s) => s.key === movingFrom)

  function moveAll(from: number | null, to: number | null) {
    setMovingFrom(null)
    const ids = (items ?? [])
      .filter((i) => i.category_id === from && !drafts.has(i.id) && !leaving.has(i.id))
      .map((i) => i.id)
    // Each goes to the end of the list order, so they must reach the server in list order.
    patchItems(ids, { category_id: to, before_id: null }, true)
  }

  function dropItem(id: number, target: DropTarget) {
    if (target.zone === NEW_CATEGORY_ZONE) {
      const rect = newCategoryDrop.current!.getBoundingClientRect()
      setParked({ id, from: { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 } })
      return
    }
    const [sectionKey, list] = target.zone.split('|')
    const section = sections.find((s) => s.key === sectionKey)
    const moving = items?.find((i) => i.id === id)
    if (!items || !section || !moving) return
    const checked = list === 'done'
    const rest = items.filter((i) => i.id !== id)
    const zone = rest.filter((i) => i.category_id === section.categoryId && i.checked === checked && !drafts.has(i.id))

    const patch: ItemPatch = {}
    if (moving.checked !== checked) patch.checked = checked
    if (moving.category_id !== section.categoryId) patch.category_id = section.categoryId
    // An empty zone shows the item wherever it is in the list order, so it keeps its place.
    if (zone.length > 0) {
      const beforeId =
        target.index < zone.length
          ? zone[target.index].id
          : (rest[rest.indexOf(zone[zone.length - 1]) + 1]?.id ?? null)
      const currentNext = items[items.indexOf(moving) + 1]?.id ?? null
      if (beforeId !== currentNext) patch.before_id = beforeId
    }
    if (Object.keys(patch).length > 0) patchItem(id, patch)
  }

  async function chooseParkedCategory(name: string): Promise<boolean> {
    const existing = categories.find((c) => c.name.toLowerCase() === name.toLowerCase())
    if (existing) {
      parkedCategory.current = { id: existing.id }
      return true
    }
    try {
      const created = await api.createCategory(name)
      const [nextCategories, nextOrder] = await Promise.all([api.listCategories(), api.categoryOrder()])
      parkedCategory.current = { id: created.id, categories: nextCategories, order: nextOrder }
      return true
    } catch (err) {
      failed(err, conflictMessage(err))
      return false
    }
  }

  /** The parked item flies out of the circle: into its new category, or back where it was. */
  function unpark() {
    if (!parked) return
    const choice = parkedCategory.current
    parkedCategory.current = null
    prepareLayoutPass({ drop: { key: `item:${parked.id}`, point: parked.from, scale: 0.1 } })
    flushSync(() => {
      if (choice?.categories) setCategories(choice.categories)
      if (choice?.order) setCategoryOrder(choice.order)
      if (choice && choice.id !== items?.find((i) => i.id === parked.id)?.category_id) {
        patchItem(parked.id, { category_id: choice.id })
      }
      setParked(null)
    })
  }

  const { drag, grab } = useListDrag<number>('item:', dropItem)
  useLayoutEffect(() => {
    dragging.current = drag !== null
  })
  useEffect(() => {
    if (drag || !reloadAfterDrag.current) return
    reloadAfterDrag.current = false
    // oxlint-disable-next-line react/set-state-in-effect -- reload only sets state after its fetch resolves
    void reload()
  }, [drag, reload])

  const settled = (rows: Item[]) => rows.filter((i) => !leaving.has(i.id))
  const settledCount = (section: Section) => settled(section.open).length + settled(section.done).length

  function sectionMenu(section: Section) {
    const open = settled(section.open)
    const all = [...open, ...settled(section.done)]
    if (all.length === 0) return null
    return (
      <MoreMenu
        label={section.title ? `Actions for ${section.title}` : 'Actions for all items'}
        actions={[
          {
            label: 'Mark all as done',
            icon: <DoneAllIcon />,
            disabled: open.length === 0,
            onSelect: () => patchItems(open.map((i) => i.id), { checked: true }),
          },
          ...(categories.length > 0
            ? [{ label: 'Move all to…', icon: <DriveFileMoveIcon />, onSelect: () => setMovingFrom(section.key) }]
            : []),
          { label: 'Delete all', icon: <DeleteSweepIcon />, danger: true, onSelect: () => deleteAll(all, section.title) },
        ]}
      />
    )
  }

  function doneMenu(section: Section) {
    const done = settled(section.done)
    if (done.length === 0) return null
    return (
      <MoreMenu
        label={section.title ? `Actions for done items in ${section.title}` : 'Actions for done items'}
        actions={[
          {
            label: 'Unmark all as done',
            icon: <RemoveDoneIcon />,
            onSelect: () => patchItems(done.map((i) => i.id), { checked: false }),
          },
          { label: 'Delete all', icon: <DeleteSweepIcon />, danger: true, onSelect: () => deleteAll(done, section.title) },
        ]}
      />
    )
  }

  function renderRows(rows: Item[], zone: string): ReactNode[] {
    return withGap(
      rows,
      zone,
      drag,
      (item) => item.id === drag?.id || item.id === parked?.id,
      (item) => (
        <ItemRow
          key={item.id}
          item={item}
          preview={item.link ? previews.get(item.link) : undefined}
          previewExpanded={expandedPreviews.has(item.id)}
          brokenImages={brokenImages}
          leaving={leaving.has(item.id)}
          lifted={item.id === drag?.id || item.id === parked?.id}
          onPatch={(patch) => patchItem(item.id, patch)}
          onDelete={() => void deleteItems([item.id])}
          onLeft={() => removeItem(item.id)}
          onGrab={(e) => grab(e, item.id)}
          onTogglePreview={() =>
            setExpandedPreviews((prev) => (prev.has(item.id) ? without(prev, item.id) : new Set(prev).add(item.id)))
          }
          onImageError={(src) => setBrokenImages((prev) => new Set(prev).add(src))}
          onPasteLines={(lines) =>
            openPaste(lines, {
              item: { id: item.id, title: item.title, categoryId: item.category_id, checked: item.checked },
            })
          }
        />
      ),
      () => (
        <li
          key="drag-gap"
          ref={motionRef(`item:${drag!.id}`)}
          className="drag-gap"
          style={{ height: drag!.height }}
          aria-hidden="true"
          data-no-ghost=""
        />
      ),
    )
  }

  const noticeElement = notice && (
    <ErrorNotice
      key={notice.id}
      message={notice.message}
      floating={!managing && !parked}
      onDismiss={() => setNotice(null)}
    />
  )

  return (
    <div className="app">
      <header className="topbar">
        <span className="brand">
          <Logo />
          <span className="brand-name">CheckCheck</span>
        </span>
        <div className="topbar-actions">
          <TopbarButton label="Connect phone" icon={<QrIcon />} onClick={() => setConnecting(true)} />
          <TopbarButton
            label="Connect AI"
            shortLabel="AI"
            icon={<SparkleIcon />}
            onClick={() => setConnectingAssistant(true)}
          />
          <TopbarButton label="Sign out" icon={<LogoutIcon />} onClick={() => setConfirmingSignOut(true)} />
        </div>
      </header>

      <main ref={main} data-drag-root="">
        {deletedShown ? (
          <RecentlyDeleted
            api={api}
            refresh={catchUps}
            report={report}
            onBack={closeDeleted}
            onRestored={addRestored}
            onFailed={failed}
            onStale={() => void reload()}
          />
        ) : paste ? (
          <AddItems
            paste={paste}
            message={pasteMessage(paste.target, items ?? [])}
            onChoose={choosePasted}
            onBack={closePaste}
            onAdd={(lines) => {
              closePaste()
              void addLines(lines, paste.target)
            }}
          />
        ) : items === null ? (
          loadFailed ? (
            <div className="empty">
              <p>Couldn't load your checklist.</p>
              <button className="btn btn-tonal" type="button" onClick={() => void reload()}>
                Try again
              </button>
            </div>
          ) : (
            <p className="empty" role="status">
              Loading…
            </p>
          )
        ) : (
          <>
            <div className="summary">
              <p>{summaryText(counts.open, counts.done)}</p>
              {/* Without categories the only section has no heading to carry its menu. */}
              {sections[0]?.title === null && sectionMenu(sections[0])}
            </div>
            <div className={drag ? 'board is-spread' : 'board'}>
              {sections.map((section) => (
                <section
                  key={section.key}
                  className="section"
                  aria-labelledby={section.title ? `section-${section.key}` : undefined}
                >
                  {section.title && (
                    <div ref={motionRef(`title:${section.key}`)} className="list-head section-head">
                      <h2 id={`section-${section.key}`} className="section-title">
                        {section.title}
                      </h2>
                      {sectionMenu(section)}
                    </div>
                  )}
                  <ul className="list" data-zone={`${section.key}|open`}>
                    {renderRows(section.open, `${section.key}|open`)}
                    <AddItemLine
                      motionKey={`add:${section.key}`}
                      categoryId={section.categoryId}
                      label={section.title ? `Add item to ${section.title}` : 'Add item'}
                      onCreate={createItem}
                      onRename={(id, title) => patchItem(id, { title })}
                      onRelease={(id) => releaseDraft(id, section.key)}
                      onDiscard={(id) => void discardDraft(id)}
                      onPasteLines={(lines) =>
                        openPaste(lines, { section: { categoryId: section.categoryId, title: section.title } })
                      }
                    />
                  </ul>
                  {(section.done.length > 0 || drag) && (
                    <div className="done">
                      <div ref={motionRef(`done:${section.key}`)} className="list-head done-head">
                        <h3 className="done-title">Done</h3>
                        {doneMenu(section)}
                      </div>
                      <ul className="list list-done" data-zone={`${section.key}|done`}>
                        {renderRows(section.done, `${section.key}|done`)}
                      </ul>
                    </div>
                  )}
                </section>
              ))}
            </div>
            <div className="board-footer">
              <button className="btn btn-tonal" type="button" onClick={() => setManaging(true)}>
                <LabelIcon />
                Manage categories
              </button>
              <button className="btn btn-tonal" type="button" onClick={openDeleted}>
                <AutoDeleteIcon />
                Recently deleted
              </button>
            </div>
            <div
              ref={newCategoryDrop}
              className={newCategoryClass(drag?.target.zone === NEW_CATEGORY_ZONE, drag !== null, parked !== null)}
              data-new-category=""
              aria-hidden="true"
            >
              <NewLabelIcon />
            </div>
          </>
        )}
      </main>

      {connecting && <ConnectPhone onClose={() => setConnecting(false)} />}
      {connectingAssistant && <ConnectAssistant onClose={() => setConnectingAssistant(false)} />}
      {confirmingSignOut && (
        <ConfirmDialog
          title="Sign out?"
          message="You will need the token to sign in again."
          confirmLabel="Sign out"
          onConfirm={onSignOut}
          onCancel={() => setConfirmingSignOut(false)}
        />
      )}
      {parked && (
        <NewCategoryDialog
          itemTitle={items?.find((i) => i.id === parked.id)?.title ?? ''}
          notice={noticeElement}
          onSubmit={chooseParkedCategory}
          onClose={() => {
            setNotice(null)
            unpark()
          }}
        />
      )}
      {pendingClear && (
        <ConfirmDialog
          title={pendingClear.title}
          message={pendingClear.message}
          confirmLabel="Delete all"
          onConfirm={() => confirmClear(pendingClear.ids)}
          onCancel={() => setPendingClear(null)}
        />
      )}
      {movingSection && (
        <MoveItemsDialog
          message={moveMessage(movingSection.title ?? '', settledCount(movingSection))}
          targets={sections
            .filter((s) => s !== movingSection)
            .map((s) => ({ key: s.key, categoryId: s.categoryId, name: s.title ?? '', count: settledCount(s) }))}
          onMove={(categoryId) => moveAll(movingSection.categoryId, categoryId)}
          onCancel={() => setMovingFrom(null)}
        />
      )}
      {managing ? (
        <CategoryManager
          categories={categories}
          order={categoryOrder}
          uncategorizedCount={items?.filter((i) => i.category_id === null).length ?? 0}
          onReorder={(order) => void reorderCategories(order)}
          itemCounts={counts.totalByCategory}
          notice={noticeElement}
          onClose={() => {
            setManaging(false)
            setNotice(null)
          }}
          onCreate={createCategory}
          onRename={renameCategory}
          onDelete={deleteCategory}
        />
      ) : (
        !parked && noticeElement
      )}
    </div>
  )
}

type TopbarButtonProps = {
  label: string
  shortLabel?: string
  icon: ReactNode
  onClick: () => void
}

function TopbarButton({ label, shortLabel = label, icon, onClick }: TopbarButtonProps) {
  return (
    <button className="topbar-btn" type="button" aria-label={label} title={label} onClick={onClick}>
      {icon}
      <span className="topbar-btn-label">{shortLabel}</span>
    </button>
  )
}

function newCategoryClass(over: boolean, dragging: boolean, holding: boolean): string {
  let className = 'new-category-drop'
  if (dragging || holding) className += ' is-shown'
  if (over || holding) className += ' is-over'
  return className
}

/** `before_id` reorders: the item moves directly before that one, or to the end for null. */
function applyPatch(items: Item[], id: number, patch: ItemPatch): Item[] {
  const { before_id: beforeId, ...fields } = patch
  const next = items.map((i) => (i.id === id ? { ...i, ...fields } : i))
  if (beforeId === undefined) return next
  const from = next.findIndex((i) => i.id === id)
  if (from < 0) return next
  const [moving] = next.splice(from, 1)
  const to = beforeId === null ? -1 : next.findIndex((i) => i.id === beforeId)
  next.splice(to < 0 ? next.length : to, 0, moving)
  return next
}

/** Only adds: a response's null preview can be older than the event that already brought one. */
function withPreviews(previews: ReadonlyMap<string, Preview>, items: Item[]): ReadonlyMap<string, Preview> {
  let next: Map<string, Preview> | undefined
  for (const { link, preview } of items) {
    if (!link || !preview) continue
    next ??= new Map(previews)
    next.set(link, preview)
  }
  return next ?? previews
}

function pasteMessage(target: PasteTarget, items: Item[]): string {
  if ('section' in target) {
    return target.section.title ? `Choose the lines to add to “${target.section.title}”.` : 'Choose the lines to add.'
  }
  // The title as it is now: leaving the main page saves what was typed into it.
  const title = items.find((i) => i.id === target.item.id)?.title ?? target.item.title
  return `Choose the lines to add below “${title}”.`
}

function moveMessage(title: string, count: number): string {
  return `Choose a category for ${count === 1 ? 'the item' : `the ${count} items`} in “${title}”.`
}

function notDoneMessage(open: number, total: number): string {
  if (total === 1) return "This item isn't done yet."
  if (open === total) return `None of these ${total} items are done yet.`
  return `${open} of these ${total} items ${open === 1 ? "isn't" : "aren't"} done yet.`
}

function summaryText(open: number, done: number): string {
  if (open + done === 0) return 'Nothing to do'
  if (open === 0) return `All ${done} done`
  return `${open} to do · ${done} done`
}
