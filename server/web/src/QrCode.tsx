import { useMemo } from 'react'
import { encode } from 'uqr'

type Props = {
  value: string
  label: string
}

const QUIET_ZONE = 3
const RADIUS = 0.35

type Vec = readonly [number, number]

// Clockwise from the top-left. `side` points away from the module through the corner; `into` is the
// edge that arrives at the corner and `out` the edge that leaves it.
const CORNERS = [
  { side: [-1, -1], into: [0, -1], out: [1, 0] },
  { side: [1, -1], into: [1, 0], out: [0, 1] },
  { side: [1, 1], into: [0, 1], out: [-1, 0] },
  { side: [-1, 1], into: [-1, 0], out: [0, -1] },
] as const

const num = (n: number) => String(Math.round(n * 1000) / 1000)
const point = ([x, y]: Vec) => `${num(x)} ${num(y)}`
const step = ([x, y]: Vec, [dx, dy]: Vec, by: number): Vec => [x + dx * by, y + dy * by]
const arc = (sweep: 0 | 1, to: Vec) => `A${num(RADIUS)} ${num(RADIUS)} 0 0 ${sweep} ${point(to)}`

// Every subpath winds clockwise, so overlaps and shared edges union under the nonzero fill rule.
function modulePath(data: boolean[][], size: number) {
  const dark = (x: number, y: number) => x >= 0 && y >= 0 && x < size && y < size && data[y][x]
  let path = ''

  data.forEach((row, y) => {
    let x = 0
    while (x < size) {
      if (!row[x]) {
        x++
        continue
      }
      let run = 1
      while (row[x + run]) run++
      CORNERS.forEach(({ side: [sx, sy], into, out }, i) => {
        const cell = sx < 0 ? x : x + run - 1
        const corner: Vec = [sx < 0 ? x : x + run, sy < 0 ? y : y + 1]
        const alone = !dark(cell + sx, y) && !dark(cell, y + sy) && !dark(cell + sx, y + sy)
        path += i === 0 ? 'M' : 'L'
        path += alone ? point(step(corner, into, -RADIUS)) + arc(1, step(corner, out, RADIUS)) : point(corner)
      })
      path += 'Z'
      x += run
    }
  })

  data.forEach((row, y) =>
    row.forEach((isDark, x) => {
      if (isDark) return
      for (const { side: [sx, sy], into, out } of CORNERS) {
        if (!dark(x + sx, y) || !dark(x, y + sy)) continue
        const corner: Vec = [sx < 0 ? x : x + 1, sy < 0 ? y : y + 1]
        path += `M${point(corner)}L${point(step(corner, out, RADIUS))}${arc(0, step(corner, into, -RADIUS))}Z`
      }
    }),
  )
  return path
}

export function QrCode({ value, label }: Props) {
  const { size, path } = useMemo(() => {
    const { size, data } = encode(value, { ecc: 'M', border: 0 })
    return { size, path: modulePath(data, size) }
  }, [value])

  const extent = size + 2 * QUIET_ZONE
  return (
    <svg className="qr" viewBox={`${-QUIET_ZONE} ${-QUIET_ZONE} ${extent} ${extent}`} role="img" aria-label={label}>
      <path d={path} fill="currentColor" />
    </svg>
  )
}
