import { useLayoutEffect, useRef, useState } from 'react'
import type { Preview } from './api'
import { ExpandIcon } from './icons'
import { cloneVisual, Motion, reducedMotion, run, SPRINGS } from './motion'

type Props = {
  link: string
  preview: Preview
  expanded: boolean
  springIn: boolean
  /** Image and icon URLs that failed to load, which are left out. */
  brokenImages: ReadonlySet<string>
  onToggle: () => void
  onImageError: (src: string) => void
}

export function LinkPreview({ link, preview, expanded, springIn, brokenImages, onToggle, onImageError }: Props) {
  // Only a click springs the details open, not a remount that finds them open.
  const [toggled, setToggled] = useState(false)
  const body = useRef<HTMLDivElement>(null)
  const label = useRef<HTMLAnchorElement>(null)
  const labelFrom = useRef<{ left: number; top: number } | null>(null)
  const labelMotion = useRef<Motion | null>(null)
  const loadable = (src: string | undefined) => (src && !brokenImages.has(src) ? src : undefined)
  const icon = loadable(preview.icon)
  const image = loadable(preview.image)
  const open = expanded && !!(image || preview.description)
  const { site, title } = labelOf(link, preview)

  // Beside an image the label moves over; it springs there from where it was.
  useLayoutEffect(() => {
    const from = labelFrom.current
    const el = label.current
    labelFrom.current = null
    if (!from || !el) return
    const m = (labelMotion.current ??= new Motion())
    m.el = el
    m.configure(SPRINGS.layout)
    m.x.value += from.left - el.offsetLeft
    m.y.value += from.top - el.offsetTop
    m.write()
    run(m)
  }, [open, image])

  function measureLabel() {
    const el = label.current
    if (el) labelFrom.current = { left: el.offsetLeft, top: el.offsetTop }
  }

  function toggle() {
    setToggled(true)
    measureLabel()
    // With reduced motion the rows below get no transform, so the copies would paint over them.
    if (open && !reducedMotion.matches) leaveBehind(body.current!)
    onToggle()
  }

  let className = 'link-preview'
  if (open) className += ' is-expanded'
  if (springIn) className += ' is-arriving'
  let bodyClass = 'link-preview-body'
  if (open && image) bodyClass += ' has-image'
  if (toggled) bodyClass += ' is-toggled'

  return (
    <div className={className}>
      <div ref={body} className={bodyClass}>
        {open && image && (
          <a
            className="link-preview-image"
            href={link}
            target="_blank"
            rel="noopener noreferrer"
            tabIndex={-1}
            aria-hidden="true"
          >
            <img
              src={image}
              alt=""
              referrerPolicy="no-referrer"
              loading="lazy"
              onError={() => {
                measureLabel()
                onImageError(image)
              }}
            />
          </a>
        )}
        <div className="link-preview-line">
          <a ref={label} className="link-preview-link" href={link} target="_blank" rel="noopener noreferrer">
            {icon && (
              <img
                className="link-preview-icon"
                src={icon}
                alt=""
                referrerPolicy="no-referrer"
                loading="lazy"
                onError={() => onImageError(icon)}
              />
            )}
            <span className="link-preview-site">{site}</span>
            {title && (
              <>
                <span className="link-preview-dot" aria-hidden="true">
                  ·
                </span>
                <span className="link-preview-title">{title}</span>
              </>
            )}
          </a>
          {(image || preview.description) && (
            <button
              className="icon-btn link-preview-toggle"
              type="button"
              aria-label="Details"
              title="Details"
              aria-expanded={open}
              onClick={toggle}
            >
              <ExpandIcon />
            </button>
          )}
        </div>
        {open && preview.description && <p className="link-preview-description">{preview.description}</p>}
      </div>
    </div>
  )
}

/** What the line says: the site, then the page's title when it has one. */
function labelOf(link: string, preview: Preview): { site: string; title?: string } {
  return { site: preview.site_name ?? hostOf(link), title: preview.title }
}

/** The link's host without `www.`, or the whole link if the browser can't parse it. */
function hostOf(link: string): string {
  try {
    return new URL(link).hostname.replace(/^www\./, '')
  } catch {
    return link
  }
}

/** Copies of the closing image and description, fading where they were as the label and rows move over them. */
function leaveBehind(body: HTMLElement) {
  const container = body.parentElement!
  for (const el of body.querySelectorAll<HTMLElement>('.link-preview-image, .link-preview-description')) {
    const ghost = cloneVisual(el)
    ghost.classList.add('link-preview-ghost')
    ghost.style.left = `${el.offsetLeft}px`
    ghost.style.top = `${el.offsetTop}px`
    ghost.style.width = `${el.offsetWidth}px`
    container.prepend(ghost)
    const remove = () => ghost.remove()
    ghost.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 150, easing: 'ease-out' }).finished.then(remove, remove)
  }
}
