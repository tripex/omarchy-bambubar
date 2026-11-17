import QtQuick
import qs.Commons as Commons

// One filament spool: a disc in the filament's colours (multicolour filament
// gets one slice per colour), a hub in the panel background, and a ring when
// it feeds the nozzle that is printing. A faint outline keeps black filament
// visible on a dark theme and white on a light one. An empty slot is the
// outline alone.
Item {
  id: root

  property var colors: []
  property bool empty: false
  property bool active: false
  property real size: 28
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property color hole: Commons.Color.popups.background

  width: size
  height: size
  implicitWidth: size
  implicitHeight: size

  onColorsChanged: canvas.requestPaint()
  onEmptyChanged: canvas.requestPaint()
  onActiveChanged: canvas.requestPaint()
  onForegroundChanged: canvas.requestPaint()
  onAccentChanged: canvas.requestPaint()
  onHoleChanged: canvas.requestPaint()

  Canvas {
    id: canvas
    anchors.fill: parent

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var c = width / 2
      var ring = Math.max(2, Math.round(width * 0.08))
      var r = c - ring - 1.5
      var fg = root.foreground
      var outline = Qt.rgba(fg.r, fg.g, fg.b, root.empty ? 0.3 : 0.4)
      var list = root.colors || []

      if (root.active) {
        ctx.beginPath()
        ctx.arc(c, c, c - ring / 2, 0, 2 * Math.PI)
        ctx.lineWidth = ring
        ctx.strokeStyle = root.accent
        ctx.stroke()
      }

      if (!root.empty && list.length > 0) {
        var slice = 2 * Math.PI / list.length
        for (var i = 0; i < list.length; i++) {
          ctx.beginPath()
          ctx.moveTo(c, c)
          ctx.arc(c, c, r, -Math.PI / 2 + i * slice, -Math.PI / 2 + (i + 1) * slice)
          ctx.closePath()
          ctx.fillStyle = list[i]
          ctx.fill()
        }
      }

      ctx.lineWidth = 1
      ctx.strokeStyle = outline
      ctx.beginPath()
      ctx.arc(c, c, r, 0, 2 * Math.PI)
      ctx.stroke()

      ctx.beginPath()
      ctx.arc(c, c, r * 0.32, 0, 2 * Math.PI)
      ctx.fillStyle = root.hole
      ctx.fill()
      ctx.stroke()
    }
  }
}
