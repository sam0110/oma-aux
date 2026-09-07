import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root

  moduleName: "sam0110.oma-aux"
  ipcTarget: "sam0110.oma-aux"

  readonly property string pluginDir: Qt.resolvedUrl(".").toString()
    .replace(/^file:\/\//, "").replace(/\/$/, "")
  property var graph: ({ "sources": [], "destinations": [], "links": [] })
  property string selectedSourceKey: ""
  property bool loading: false
  property string error: ""
  property string pendingConnection: ""
  property string drawingSourceKey: ""
  property real drawingX: 0
  property real drawingY: 0

  readonly property var sources: graph.sources || []
  readonly property var destinations: graph.destinations || []
  readonly property var links: graph.links || []
  readonly property int routeCount: countRoutes(links)
  readonly property var selectedSource: sourceByKey(selectedSourceKey)
  readonly property int selectedSourceId: selectedSource ? selectedSource.id : -1

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function sourceByKey(key) {
    for (var i = 0; i < sources.length; i++)
      if (sources[i].key === key) return sources[i]
    return null
  }

  function linksBetween(outputNode, inputNode) {
    var found = []
    for (var i = 0; i < links.length; i++) {
      var link = links[i]
      if (link.outputNode === outputNode && link.inputNode === inputNode)
        found.push(link)
    }
    return found
  }

  function countRoutes(allLinks) {
    var routes = ({})
    for (var i = 0; i < allLinks.length; i++)
      routes[allLinks[i].outputNode + ":" + allLinks[i].inputNode] = true
    return Object.keys(routes).length
  }

  function connectionState(source, destination) {
    if (!source || !destination) return "disconnected"
    var count = linksBetween(source.id, destination.id).length
    if (count === 0) return "disconnected"
    var outputCount = (source.ports || []).length
    var inputCount = (destination.ports || []).length
    var expected = outputCount === 1 || inputCount === 1
      ? Math.max(outputCount, inputCount)
      : Math.min(outputCount, inputCount)
    return count >= expected ? "connected" : "partial"
  }

  function kindLabel(kind) {
    if (kind === "playback") return "PLAYBACK"
    if (kind === "source") return "SOURCE"
    if (kind === "monitor") return "MONITOR"
    if (kind === "recording") return "RECORDING"
    if (kind === "device") return "OUTPUT"
    return "FILTER"
  }

  function portSummary(endpoint) {
    var channels = []
    var ports = endpoint.ports || []
    for (var i = 0; i < ports.length; i++) {
      var channel = String(ports[i].channel || "")
      if (channel && channels.indexOf(channel) < 0) channels.push(channel)
    }
    return channels.length ? channels.join(" / ") : ports.length + (ports.length === 1 ? " port" : " ports")
  }

  function applySnapshot(line) {
    if (!opened) return
    try {
      var parsed = JSON.parse(String(line || ""))
      if (!parsed.sources || !parsed.destinations || !parsed.links) return
      graph = parsed
      loading = false
      error = ""
      if (!selectedSource)
        selectedSourceKey = sources.length ? sources[0].key : ""
    } catch (e) {
      error = "Could not understand the PipeWire graph"
      loading = false
    }
  }

  function toggleConnectionFor(sourceId, destinationId) {
    if (sourceId < 0 || actionProc.running) return
    pendingConnection = sourceId + ":" + destinationId
    error = ""
    actionProc.command = [
      pluginDir + "/bin/oma-aux",
      "toggle",
      String(sourceId),
      String(destinationId)
    ]
    actionProc.running = true
  }

  function toggleConnection(destinationId) {
    toggleConnectionFor(selectedSourceId, destinationId)
  }

  function beginConnection(sourceKey, point) {
    selectedSourceKey = sourceKey
    drawingSourceKey = sourceKey
    drawingX = point.x
    drawingY = point.y
  }

  function updateConnection(point) {
    drawingX = Math.max(0, Math.min(graphBoard.width, point.x))
    drawingY = Math.max(0, Math.min(graphBoard.height, point.y))
  }

  function finishConnection(point) {
    updateConnection(point)
    var source = sourceByKey(drawingSourceKey)
    var destination = graphBoard.destinationAt(point.x, point.y)
    drawingSourceKey = ""
    if (source && destination)
      toggleConnectionFor(source.id, destination.id)
  }

  onOpenedChanged: {
    if (opened) {
      loading = sources.length === 0
      error = ""
    } else {
      pendingConnection = ""
      drawingSourceKey = ""
    }
  }

  Process {
    id: graphWatcher
    command: [root.pluginDir + "/bin/oma-aux", "watch"]
    running: root.opened
    stdout: SplitParser { onRead: function(line) { root.applySnapshot(line) } }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (root.opened && String(text || "").trim()) {
        root.error = String(text).trim()
        root.loading = false
      }
    }
    onExited: function(exitCode) {
      if (root.opened && exitCode !== 0 && root.error === "") {
        root.error = "PipeWire graph watcher stopped"
        root.loading = false
      }
    }
  }

  Process {
    id: actionProc
    stdout: SplitParser { onRead: function(line) { root.applySnapshot(line) } }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text || "").trim()) root.error = String(text).trim()
    }
    onExited: function(exitCode) {
      root.pendingConnection = ""
      if (exitCode !== 0 && root.error === "") root.error = "Could not change the connection"
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰓃"
    onPressed: root.toggle()
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(940))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: outerScroll
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: contentColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Column {
          id: contentColumn
          width: outerScroll.availableWidth
          spacing: Style.space(14)

        Row {
          width: parent.width
          spacing: Style.space(12)

          Text {
            text: "󰓃"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            width: parent.width - Style.space(52)
            spacing: Style.space(2)

            Text {
              text: "Oma Aux"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              text: root.loading
                ? "Reading the PipeWire graph…"
                : root.sources.length + " sources  ·  " + root.destinations.length + " destinations  ·  " + root.routeCount + " routes"
              color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.62)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        Rectangle {
          visible: root.error !== ""
          width: parent.width
          implicitHeight: errorText.implicitHeight + Style.space(18)
          radius: Style.cornerRadius
          color: Qt.rgba(0.85, 0.20, 0.20, 0.15)

          Text {
            id: errorText
            anchors.fill: parent
            anchors.margins: Style.space(9)
            text: root.error
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        Text {
          visible: !root.loading && root.sources.length === 0
          width: parent.width
          text: "No routable audio ports are currently available."
          color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.62)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
          horizontalAlignment: Text.AlignHCenter
        }

        Column {
          visible: root.sources.length > 0
          width: parent.width
          spacing: Style.space(8)

          Row {
            width: parent.width

            PanelSectionHeader {
              width: graphBoard.nodeWidth
              text: "SOURCES"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            PanelSectionHeader {
              width: parent.width - graphBoard.nodeWidth * 2
              text: "ROUTES / FILTERS"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              horizontalAlignment: Text.AlignHCenter
            }

            PanelSectionHeader {
              width: graphBoard.nodeWidth
              text: "DESTINATIONS"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              horizontalAlignment: Text.AlignRight
            }
          }

          Item {
            id: graphBoard
            width: parent.width
            implicitHeight: Math.max(root.sources.length, root.destinations.length) * rowPitch
            height: implicitHeight

            readonly property real nodeWidth: Math.min(Style.space(250), width * 0.32)
            readonly property real nodeHeight: Style.space(64)
            readonly property real rowPitch: Style.space(76)
            readonly property real socketRadius: Style.space(6)

            function destinationAt(x, y) {
              if (x < width - nodeWidth - Style.space(24)) return null
              var index = Math.floor(y / rowPitch)
              if (index < 0 || index >= root.destinations.length) return null
              if (y - index * rowPitch > nodeHeight) return null
              return root.destinations[index]
            }

            Rectangle {
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              anchors.horizontalCenter: parent.horizontalCenter
              width: Math.max(Style.space(96), graphBoard.width - graphBoard.nodeWidth * 2 - Style.space(72))
              radius: Style.cornerRadius
              color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.035)
              border.width: 1
              border.color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.10)

              Text {
                anchors.top: parent.top
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.topMargin: Style.space(8)
                text: "FILTER SLOTS"
                color: root.bar.foreground
                opacity: 0.26
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1.2
              }
            }

            Canvas {
              id: routeCanvas
              anchors.fill: parent
              property var graphData: root.graph
              property string highlightedSource: root.selectedSourceKey
              property string drawingSource: root.drawingSourceKey
              property real pointerX: root.drawingX
              property real pointerY: root.drawingY

              onGraphDataChanged: requestPaint()
              onHighlightedSourceChanged: requestPaint()
              onDrawingSourceChanged: requestPaint()
              onPointerXChanged: requestPaint()
              onPointerYChanged: requestPaint()
              onWidthChanged: requestPaint()
              onHeightChanged: requestPaint()

              onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                ctx.lineCap = "round"

                for (var sourceIndex = 0; sourceIndex < root.sources.length; sourceIndex++) {
                  var source = root.sources[sourceIndex]
                  for (var destinationIndex = 0; destinationIndex < root.destinations.length; destinationIndex++) {
                    var destination = root.destinations[destinationIndex]
                    var state = root.connectionState(source, destination)
                    if (state === "disconnected") continue

                    var x1 = graphBoard.nodeWidth
                    var y1 = sourceIndex * graphBoard.rowPitch + graphBoard.nodeHeight / 2
                    var x2 = graphBoard.width - graphBoard.nodeWidth
                    var y2 = destinationIndex * graphBoard.rowPitch + graphBoard.nodeHeight / 2
                    var span = x2 - x1
                    ctx.beginPath()
                    ctx.moveTo(x1, y1)
                    ctx.bezierCurveTo(x1 + span * 0.42, y1, x2 - span * 0.42, y2, x2, y2)
                    ctx.strokeStyle = source.key === root.selectedSourceKey
                      ? Color.accent
                      : Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.42)
                    ctx.lineWidth = state === "partial" ? 2 : 3
                    ctx.stroke()

                    var middleX = (x1 + x2) / 2
                    var middleY = (y1 + y2) / 2
                    ctx.beginPath()
                    ctx.arc(middleX, middleY, Style.space(4), 0, Math.PI * 2)
                    ctx.fillStyle = state === "partial"
                      ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.65)
                      : Color.accent
                    ctx.fill()
                  }
                }

                if (root.drawingSourceKey !== "") {
                  var drawingIndex = -1
                  for (var i = 0; i < root.sources.length; i++)
                    if (root.sources[i].key === root.drawingSourceKey) drawingIndex = i
                  if (drawingIndex >= 0) {
                    var startX = graphBoard.nodeWidth
                    var startY = drawingIndex * graphBoard.rowPitch + graphBoard.nodeHeight / 2
                    var control = Math.max(Style.space(40), (root.drawingX - startX) * 0.45)
                    ctx.beginPath()
                    ctx.moveTo(startX, startY)
                    ctx.bezierCurveTo(startX + control, startY, root.drawingX - control, root.drawingY, root.drawingX, root.drawingY)
                    ctx.strokeStyle = Color.accent
                    ctx.lineWidth = 3
                    ctx.stroke()
                  }
                }
              }
            }

            Repeater {
              model: root.sources

              delegate: CursorSurface {
                required property var modelData
                required property int index
                x: 0
                y: index * graphBoard.rowPitch
                width: graphBoard.nodeWidth
                height: graphBoard.nodeHeight
                current: root.selectedSourceKey === modelData.key
                foreground: root.bar.foreground
                fill: current
                  ? Style.selectedFillFor(root.bar.foreground, Color.accent)
                  : Style.hoverFillFor(root.bar.foreground, Color.accent)

                MouseArea {
                  anchors.fill: parent
                  onClicked: root.selectedSourceKey = modelData.key
                }

                Column {
                  anchors.left: parent.left
                  anchors.right: sourceSocket.left
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  spacing: Style.space(2)

                  Text {
                    width: parent.width
                    text: modelData.label
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: root.selectedSourceKey === modelData.key
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    text: root.kindLabel(modelData.kind) + "  ·  " + root.portSummary(modelData)
                    color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.55)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                Rectangle {
                  id: sourceSocket
                  z: 2
                  anchors.right: parent.right
                  anchors.rightMargin: -graphBoard.socketRadius
                  anchors.verticalCenter: parent.verticalCenter
                  width: graphBoard.socketRadius * 2
                  height: width
                  radius: width / 2
                  color: root.selectedSourceKey === modelData.key ? Color.accent : root.bar.foreground
                  border.width: 2
                  border.color: root.bar.background

                  MouseArea {
                    anchors.fill: parent
                    anchors.margins: -Style.space(10)
                    cursorShape: Qt.CrossCursor
                    enabled: !actionProc.running
                    onPressed: function(mouse) {
                      var point = mapToItem(graphBoard, mouse.x, mouse.y)
                      root.beginConnection(modelData.key, point)
                    }
                    onPositionChanged: function(mouse) {
                      if (pressed) root.updateConnection(mapToItem(graphBoard, mouse.x, mouse.y))
                    }
                    onReleased: function(mouse) {
                      root.finishConnection(mapToItem(graphBoard, mouse.x, mouse.y))
                    }
                    onCanceled: root.drawingSourceKey = ""
                  }
                }
              }
            }

            Repeater {
              model: root.destinations

              delegate: CursorSurface {
                required property var modelData
                required property int index
                readonly property string routeState: root.connectionState(root.selectedSource, modelData)
                readonly property bool connected: routeState === "connected"
                readonly property bool partial: routeState === "partial"
                readonly property bool pending: root.pendingConnection
                  === root.selectedSourceId + ":" + modelData.id
                x: graphBoard.width - width
                y: index * graphBoard.rowPitch
                width: graphBoard.nodeWidth
                height: graphBoard.nodeHeight
                current: connected || partial
                foreground: root.bar.foreground
                fill: current
                  ? Style.selectedFillFor(root.bar.foreground, Color.accent)
                  : Style.hoverFillFor(root.bar.foreground, Color.accent)

                MouseArea {
                  anchors.fill: parent
                  enabled: root.selectedSourceId >= 0 && !actionProc.running
                  onClicked: root.toggleConnection(modelData.id)
                }

                Rectangle {
                  anchors.left: parent.left
                  anchors.leftMargin: -graphBoard.socketRadius
                  anchors.verticalCenter: parent.verticalCenter
                  width: graphBoard.socketRadius * 2
                  height: width
                  radius: width / 2
                  color: connected || partial ? Color.accent : root.bar.foreground
                  opacity: connected || partial ? 1 : 0.55
                  border.width: 2
                  border.color: root.bar.background
                }

                Row {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(14)
                  anchors.rightMargin: Style.space(10)
                  spacing: Style.space(8)

                  Column {
                    width: parent.width - destinationMark.width - parent.spacing
                    spacing: Style.space(2)

                    Text {
                      width: parent.width
                      text: modelData.label
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: connected
                      elide: Text.ElideRight
                    }

                    Text {
                      width: parent.width
                      text: root.kindLabel(modelData.kind) + "  ·  " + root.portSummary(modelData)
                      color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.55)
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }

                  Text {
                    id: destinationMark
                    anchors.verticalCenter: parent.verticalCenter
                    text: pending ? "󰔟" : (connected ? "󰌷" : (partial ? "~" : ""))
                    color: connected || partial ? Color.accent : root.bar.foreground
                    opacity: connected ? 1 : 0.75
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.title
                  }
                }
              }
            }
          }

          Text {
            width: parent.width
            text: "Drag from a source socket to a destination, or select a source and click destinations. One source can feed many destinations."
            color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.48)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }
        }
        }
      }
    }
  }
}
