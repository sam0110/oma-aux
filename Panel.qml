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

  readonly property var sources: graph.sources || []
  readonly property var destinations: graph.destinations || []
  readonly property var links: graph.links || []
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

  function toggleConnection(destinationId) {
    if (selectedSourceId < 0 || actionProc.running) return
    pendingConnection = selectedSourceId + ":" + destinationId
    error = ""
    actionProc.command = [
      pluginDir + "/bin/oma-aux",
      "toggle",
      String(selectedSourceId),
      String(destinationId)
    ]
    actionProc.running = true
  }

  onOpenedChanged: {
    if (opened) {
      loading = sources.length === 0
      error = ""
    } else {
      pendingConnection = ""
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
    contentWidth: panel.fittedContentWidth(Style.space(680))
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
                : root.sources.length + " sources  ·  " + root.destinations.length + " destinations  ·  " + root.links.length + " links"
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

        Row {
          id: routingColumns
          visible: root.sources.length > 0
          width: parent.width
          spacing: Style.space(14)

          Column {
            id: sourcePane
            width: (parent.width - parent.spacing) * 0.44
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "FROM"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            ScrollView {
              width: parent.width
              height: Math.min(sourceColumn.implicitHeight, Style.space(470))
              clip: true
              ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
              ScrollBar.vertical.policy: sourceColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

              Column {
                id: sourceColumn
                width: parent.width
                spacing: Style.space(5)

                Repeater {
                  model: root.sources

                  delegate: CursorSurface {
                    required property var modelData
                    width: sourceColumn.width
                    implicitHeight: sourceBody.implicitHeight + Style.space(16)
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
                      id: sourceBody
                      anchors.left: parent.left
                      anchors.right: parent.right
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
                  }
                }
              }
            }
          }

          Column {
            width: routingColumns.width - routingColumns.spacing - sourcePane.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: root.selectedSource ? "TO · " + root.selectedSource.label : "TO"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            ScrollView {
              width: parent.width
              height: Math.min(destinationColumn.implicitHeight, Style.space(470))
              clip: true
              ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
              ScrollBar.vertical.policy: destinationColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

              Column {
                id: destinationColumn
                width: parent.width
                spacing: Style.space(5)

                Repeater {
                  model: root.destinations

                  delegate: CursorSurface {
                    required property var modelData
                    readonly property string routeState: root.connectionState(root.selectedSource, modelData)
                    readonly property bool connected: routeState === "connected"
                    readonly property bool partial: routeState === "partial"
                    readonly property bool pending: root.pendingConnection
                      === root.selectedSourceId + ":" + modelData.id
                    width: destinationColumn.width
                    implicitHeight: destinationBody.implicitHeight + Style.space(16)
                    current: connected || partial
                    foreground: root.bar.foreground
                    fill: connected
                      ? Style.selectedFillFor(root.bar.foreground, Color.accent)
                      : Style.hoverFillFor(root.bar.foreground, Color.accent)

                    MouseArea {
                      anchors.fill: parent
                      enabled: root.selectedSourceId >= 0 && !actionProc.running
                      onClicked: root.toggleConnection(modelData.id)
                    }

                    Row {
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.leftMargin: Style.space(10)
                      anchors.rightMargin: Style.space(10)
                      spacing: Style.space(8)

                      Column {
                        id: destinationBody
                        width: parent.width - connectionMark.width - parent.spacing
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
                        id: connectionMark
                        anchors.verticalCenter: parent.verticalCenter
                        text: pending ? "󰔟" : (connected ? "󰌷" : (partial ? "~" : "󰌹"))
                        color: connected || partial ? Color.accent : root.bar.foreground
                        opacity: connected ? 1 : (partial ? 0.75 : 0.45)
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.title
                      }
                    }
                  }
                }
              }
            }
          }
        }

        Text {
          visible: root.sources.length > 0
          width: parent.width
          text: "Select a source, then click a destination to connect or disconnect all matching channels."
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
