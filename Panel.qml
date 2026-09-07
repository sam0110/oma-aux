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
  property var graph: ({ "sources": [], "destinations": [], "links": [], "routes": [], "filterBands": [] })
  property string selectedSourceKey: ""
  property string selectedRouteId: ""
  property real editorPan: 0
  property var editorEq: [0, 0, 0, 0, 0]
  property bool loading: false
  property string error: ""
  property string pendingConnection: ""
  property string drawingSourceKey: ""
  property real drawingX: 0
  property real drawingY: 0

  readonly property var sources: graph.sources || []
  readonly property var destinations: graph.destinations || []
  readonly property var routes: graph.routes || []
  readonly property var filterBands: graph.filterBands || []
  readonly property int routeCount: routes.length
  readonly property var selectedSource: sourceByKey(selectedSourceKey)
  readonly property int selectedSourceId: selectedSource ? selectedSource.id : -1
  readonly property var selectedRoute: routeById(selectedRouteId)

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function sourceByKey(key) {
    for (var i = 0; i < sources.length; i++)
      if (sources[i].key === key) return sources[i]
    return null
  }

  function destinationByKey(key) {
    for (var i = 0; i < destinations.length; i++)
      if (destinations[i].key === key) return destinations[i]
    return null
  }

  function routeById(id) {
    for (var i = 0; i < routes.length; i++)
      if (routes[i].id === id) return routes[i]
    return null
  }

  function routeBetween(source, destination) {
    if (!source || !destination) return null
    for (var i = 0; i < routes.length; i++) {
      var route = routes[i]
      if (route.sourceId === source.id && route.destinationId === destination.id)
        return route
    }
    return null
  }

  function endpointIndex(collection, key) {
    for (var i = 0; i < collection.length; i++)
      if (collection[i].key === key) return i
    return -1
  }

  function connectionState(source, destination) {
    var route = routeBetween(source, destination)
    return route ? route.status : "disconnected"
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
    try {
      var parsed = JSON.parse(String(line || ""))
      if (!parsed.sources || !parsed.destinations || !parsed.links || !parsed.routes) return
      graph = parsed
      loading = false
      error = ""
      if (!selectedSource)
        selectedSourceKey = sources.length ? sources[0].key : ""
      if (selectedRouteId !== "" && !selectedRoute)
        selectedRouteId = ""
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

  function selectRoute(route) {
    selectedRouteId = route.id
    selectedSourceKey = route.sourceKey
    editorPan = Number((route.filter || {}).pan || 0)
    var gains = (route.filter || {}).eq || [0, 0, 0, 0, 0]
    editorEq = gains.slice(0)
    Qt.callLater(revealRouteEditor)
  }

  function revealRouteEditor() {
    if (!selectedRoute || !routeEditorCard.visible) return
    var flickable = outerScroll.contentItem
    var editorY = routeEditorCard.mapToItem(contentColumn, 0, 0).y
    var maximumY = Math.max(0, flickable.contentHeight - flickable.height)
    flickable.contentY = Math.min(maximumY, Math.max(0, editorY - Style.space(12)))
  }

  function setFilter() {
    if (!selectedRoute || actionProc.running) return
    error = ""
    actionProc.command = [
      pluginDir + "/bin/oma-aux",
      "filter-set",
      String(selectedRoute.sourceId),
      String(selectedRoute.destinationId),
      JSON.stringify({ "pan": editorPan, "eq": editorEq })
    ]
    actionProc.running = true
  }

  function clearFilter() {
    if (!selectedRoute || actionProc.running) return
    error = ""
    actionProc.command = [
      pluginDir + "/bin/oma-aux",
      "filter-clear",
      String(selectedRoute.sourceId),
      String(selectedRoute.destinationId)
    ]
    actionProc.running = true
  }

  function updateEq(index, value) {
    var gains = editorEq.slice(0)
    gains[index] = Math.round(value * 10) / 10
    editorEq = gains
  }

  function toggleConnection(destinationId) {
    toggleConnectionFor(selectedSourceId, destinationId)
  }

  function beginConnection(sourceKey, point) {
    selectedSourceKey = sourceKey
    selectedRouteId = ""
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
    // Reconcile audio routes even while the panel is closed.
    running: true
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
              property string highlightedRoute: root.selectedRouteId
              property string drawingSource: root.drawingSourceKey
              property real pointerX: root.drawingX
              property real pointerY: root.drawingY

              onGraphDataChanged: requestPaint()
              onHighlightedSourceChanged: requestPaint()
              onHighlightedRouteChanged: requestPaint()
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
                    var route = root.routeBetween(source, destination)

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
                    ctx.lineWidth = route && route.id === root.selectedRouteId
                      ? 5
                      : (state === "partial" || state === "waiting" ? 2 : 3)
                    ctx.stroke()

                    var middleX = (x1 + x2) / 2
                    var middleY = (y1 + y2) / 2
                    ctx.beginPath()
                    ctx.arc(middleX, middleY, Style.space(4), 0, Math.PI * 2)
                    ctx.fillStyle = state === "partial" || state === "waiting"
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
              model: root.routes

              delegate: Rectangle {
                required property var modelData
                readonly property int sourceIndex: root.endpointIndex(root.sources, modelData.sourceKey)
                readonly property int destinationIndex: root.endpointIndex(root.destinations, modelData.destinationKey)
                visible: sourceIndex >= 0 && destinationIndex >= 0
                x: graphBoard.width / 2 - width / 2
                y: ((sourceIndex + destinationIndex) * graphBoard.rowPitch + graphBoard.nodeHeight) / 2 - height / 2
                width: Style.space(28)
                height: width
                radius: width / 2
                color: root.selectedRouteId === modelData.id
                  ? Color.accent
                  : root.bar.background
                border.width: 2
                border.color: Color.accent

                Text {
                  anchors.centerIn: parent
                  text: modelData.filtered ? "EQ" : "+"
                  color: root.selectedRouteId === modelData.id ? root.bar.background : Color.accent
                  font.family: root.bar.fontFamily
                  font.pixelSize: modelData.filtered ? Style.font.caption : Style.font.body
                  font.bold: true
                }

                MouseArea {
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.selectRoute(modelData)
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
                  onClicked: {
                    root.selectedSourceKey = modelData.key
                    root.selectedRouteId = ""
                  }
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
                    preventStealing: true
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
            visible: !root.selectedRoute
            width: parent.width
            text: "Choose a route marker to add pan and EQ, or drag from a source socket to create another route."
            color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.48)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          Rectangle {
            id: routeEditorCard
            visible: !!root.selectedRoute
            width: parent.width
            implicitHeight: filterEditor.implicitHeight + Style.space(24)
            radius: Style.cornerRadius
            color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.045)
            border.width: 1
            border.color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)

            Column {
              id: filterEditor
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(12)
              spacing: Style.space(10)

              Row {
                width: parent.width
                spacing: Style.space(8)

                Text {
                  width: parent.width - closeRoute.width - parent.spacing
                  text: {
                    var route = root.selectedRoute
                    if (!route) return ""
                    var source = root.sourceByKey(route.sourceKey)
                    var destination = root.destinationByKey(route.destinationKey)
                    return (source ? source.label : "Source") + "  →  " + (destination ? destination.label : "Destination")
                  }
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  elide: Text.ElideRight
                }

                Text {
                  id: closeRoute
                  text: "×"
                  color: root.bar.foreground
                  opacity: closeArea.containsMouse ? 1 : 0.55
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.title

                  MouseArea {
                    id: closeArea
                    anchors.fill: parent
                    anchors.margins: -Style.space(6)
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.selectedRouteId = ""
                  }
                }
              }

              Text {
                visible: root.selectedRoute && !root.selectedRoute.filtered
                width: parent.width
                text: "Insert a stereo processor on this route for independent balance and five-band equalization."
                color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.62)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              Rectangle {
                visible: root.selectedRoute && !root.selectedRoute.filtered
                width: Style.space(150)
                height: Style.space(34)
                radius: height / 2
                color: enableFilterArea.containsMouse
                  ? Style.hoverFillFor(root.bar.foreground, Color.accent)
                  : Style.selectedFillFor(root.bar.foreground, Color.accent)
                opacity: actionProc.running ? 0.5 : 1

                Text {
                  anchors.centerIn: parent
                  text: actionProc.running ? "STARTING…" : "ADD PAN + EQ"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                MouseArea {
                  id: enableFilterArea
                  anchors.fill: parent
                  hoverEnabled: true
                  enabled: !actionProc.running
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.setFilter()
                }
              }

              Column {
                visible: root.selectedRoute && root.selectedRoute.filtered
                width: parent.width
                spacing: Style.space(8)

                Row {
                  width: parent.width
                  spacing: Style.space(10)

                  Text {
                    width: Style.space(72)
                    anchors.verticalCenter: parent.verticalCenter
                    text: "PAN"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "L"
                    color: root.bar.foreground
                    opacity: 0.55
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Slider {
                    id: panSlider
                    width: parent.width - Style.space(190)
                    anchors.verticalCenter: parent.verticalCenter
                    from: -1
                    to: 1
                    stepSize: 0.05
                    value: root.editorPan
                    enabled: !actionProc.running
                    onMoved: root.editorPan = Math.round(value * 100) / 100
                    onPressedChanged: if (!pressed && root.selectedRoute && root.selectedRoute.filtered) root.setFilter()
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "R"
                    color: root.bar.foreground
                    opacity: 0.55
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    width: Style.space(54)
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.editorPan === 0
                      ? "CENTER"
                      : Math.round(Math.abs(root.editorPan) * 100) + "% " + (root.editorPan < 0 ? "L" : "R")
                    color: Color.accent
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    horizontalAlignment: Text.AlignRight
                  }
                }

                Text {
                  text: "EQUALIZER"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Repeater {
                  model: root.filterBands

                  delegate: Row {
                    required property var modelData
                    required property int index
                    width: filterEditor.width
                    spacing: Style.space(10)

                    Text {
                      width: Style.space(72)
                      anchors.verticalCenter: parent.verticalCenter
                      text: modelData
                      color: root.bar.foreground
                      opacity: 0.72
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    Slider {
                      width: parent.width - Style.space(150)
                      anchors.verticalCenter: parent.verticalCenter
                      from: -12
                      to: 12
                      stepSize: 0.5
                      value: Number(root.editorEq[index] || 0)
                      enabled: !actionProc.running
                      onMoved: root.updateEq(index, value)
                      onPressedChanged: if (!pressed && root.selectedRoute && root.selectedRoute.filtered) root.setFilter()
                    }

                    Text {
                      width: Style.space(58)
                      anchors.verticalCenter: parent.verticalCenter
                      text: {
                        var gain = Number(root.editorEq[index] || 0)
                        return (gain > 0 ? "+" : "") + gain.toFixed(1) + " dB"
                      }
                      color: Number(root.editorEq[index] || 0) === 0 ? root.bar.foreground : Color.accent
                      opacity: Number(root.editorEq[index] || 0) === 0 ? 0.55 : 1
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                      horizontalAlignment: Text.AlignRight
                    }
                  }
                }

                Text {
                  text: "REMOVE FILTERS"
                  color: removeFilterArea.containsMouse ? Color.accent : root.bar.foreground
                  opacity: actionProc.running ? 0.35 : 0.62
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true

                  MouseArea {
                    id: removeFilterArea
                    anchors.fill: parent
                    anchors.margins: -Style.space(5)
                    hoverEnabled: true
                    enabled: !actionProc.running
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.clearFilter()
                  }
                }
              }
            }
          }
        }
        }
      }
    }
  }
}
