import { useState, type PointerEvent } from 'react'
import type { Item, ItemPatch, Preview } from './api'
import { Checkbox } from './Checkbox'
import { DeleteIcon, DragIcon } from './icons'
import { LinkPreview } from './LinkPreview'
import { hurry, motionOf, motionRef } from './motion'
import { TitleField } from './TitleField'

type Props = {
  item: Item
  /** The preview of `item.link`, once the server has found one. */
  preview: Preview | undefined
  previewExpanded: boolean
  brokenImages: ReadonlySet<string>
  leaving: boolean
  /** Hidden while dragged or waiting for a new category; it stays mounted so a drag keeps its pointer. */
  lifted: boolean
  onPatch: (patch: ItemPatch) => void
  onDelete: () => void
  onLeft: () => void
  onGrab: (e: PointerEvent<HTMLElement>) => void
  onTogglePreview: () => void
  onImageError: (src: string) => void
  onPasteLines: (lines: string[]) => void
}

export function ItemRow({
  item,
  preview,
  previewExpanded,
  brokenImages,
  leaving,
  lifted,
  onPatch,
  onDelete,
  onLeft,
  onGrab,
  onTogglePreview,
  onImageError,
  onPasteLines,
}: Props) {
  // Moving to another list remounts the row; a preview it was already showing shouldn't spring in again.
  const [shownLink] = useState(() => (preview && motionOf(`item:${item.id}`) ? item.link : null))

  let className = 'item'
  if (item.checked) className += ' is-checked'
  if (leaving) className += ' is-leaving'
  if (lifted) className += ' is-lifted'

  return (
    <li
      ref={lifted ? undefined : motionRef(`item:${item.id}`)}
      className={className}
      data-drag-id={item.id}
      data-no-ghost={leaving || undefined}
      inert={leaving}
      onAnimationEnd={(e) => {
        if (leaving && e.target === e.currentTarget) onLeft()
      }}
    >
      <Checkbox
        className="item-checkbox"
        checked={item.checked}
        label={item.title}
        onChange={(checked) => {
          hurry()
          onPatch({ checked })
        }}
      />
      <TitleField
        value={item.title}
        label="Item title"
        onSave={(title) => onPatch({ title })}
        onClear={onDelete}
        onPasteLines={onPasteLines}
      />
      {item.link && preview && (
        <LinkPreview
          key={item.link}
          link={item.link}
          preview={preview}
          expanded={previewExpanded}
          springIn={item.link !== shownLink}
          brokenImages={brokenImages}
          onToggle={onTogglePreview}
          onImageError={onImageError}
        />
      )}
      <button
        className="icon-btn icon-btn-danger item-delete item-action"
        type="button"
        aria-label={`Delete ${item.title}`}
        title="Delete"
        onClick={() => {
          hurry()
          onDelete()
        }}
      >
        <DeleteIcon />
      </button>
      {/* Pointer-only, so hidden from assistive tech rather than a button that does nothing. */}
      <span className="drag-handle item-action" aria-hidden="true" title="Drag to move" onPointerDown={onGrab}>
        <DragIcon />
      </span>
    </li>
  )
}
