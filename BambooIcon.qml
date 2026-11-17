import QtQuick
import qs.Commons as Commons

// The bamboo ("Bambu") mark from the macOS app: three segmented stalks of
// falling height, drawn bottom-up. Plain rectangles, so the bar can measure
// the painted bounds and the icon follows the theme colour.
Item {
  id: root

  property real iconSize: 16
  property color color: Commons.Color.foreground

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property var stalks: [
    { x: 0.16, segments: 3, height: 0.84 },
    { x: 0.41, segments: 3, height: 0.68 },
    { x: 0.66, segments: 2, height: 0.50 }
  ]

  Repeater {
    model: root.stalks

    Item {
      id: stalk
      required property var modelData
      readonly property real gap: root.height * 0.035
      readonly property real segment: (modelData.height * root.height - gap * (modelData.segments - 1)) / modelData.segments

      x: modelData.x * root.width
      width: 0.18 * root.width
      height: root.height

      Repeater {
        model: stalk.modelData.segments

        Rectangle {
          required property int index
          y: root.height - (index + 1) * stalk.segment - index * stalk.gap
          width: stalk.width
          height: stalk.segment
          radius: width * 0.2
          color: root.color
          antialiasing: true
        }
      }
    }
  }
}
