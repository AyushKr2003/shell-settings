import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Rectangle {
    id: root

    property color foreground: Commons.Color.popups.text
    property color accent: Commons.Color.accent
    property string fontFamily: "monospace"
    property int cornerRadius: Style.cornerRadius
    property color background: Commons.Color.popups.background
    property color urgent: Commons.Color.urgent
    property string homePath: Quickshell.env("HOME") || ""

    signal selected(string path)
    signal cancelled()

    property string folderCurrentPath: root.homePath
    property var folderDirs: []
    property bool folderShowHidden: false

    anchors.fill: parent
    visible: false
    z: 200
    color: Qt.rgba(0, 0, 0, 0.45)

    focus: visible
    onVisibleChanged: if (visible) Qt.callLater(forceActiveFocus)

    MouseArea {
        anchors.fill: parent
        onClicked: root.folderPickerCancel()
        acceptedButtons: Qt.LeftButton | Qt.RightButton
    }

    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
            root.folderPickerCancel()
            event.accepted = true
        }
    }

    function open() {
        root.folderCurrentPath = root.homePath
        root.folderDirs = []
        root.folderShowHidden = false
        Qt.callLater(refreshFolderDirs)
        root.visible = true
    }

    function folderPickerUp() {
        var path = String(root.folderCurrentPath)
        var parent = path.replace(/\/+$/, "").replace(/\/[^/]*$/, "")
        if (parent === "") parent = "/"
        root.folderCurrentPath = parent
        refreshFolderDirs()
    }

    function folderPickerEnter(name) {
        var path = String(root.folderCurrentPath)
        if (!path.endsWith("/")) path += "/"
        root.folderCurrentPath = path + name
        refreshFolderDirs()
    }

    function folderPickerSelect() {
        root.selected(root.folderCurrentPath)
        root.visible = false
    }

    function folderPickerCancel() {
        root.cancelled()
        root.visible = false
    }

    function refreshFolderDirs() {
        if (folderListProcess.running) return
        var path = String(root.folderCurrentPath)
        folderListProcess.command = ["bash", "-c",
            "find " + Util.shellQuote(path) + " -maxdepth 1 -mindepth 1 -type d " + (root.folderShowHidden ? "" : "! -name '.*' ") + "| sort"]
        folderListProcess.running = true
    }

    property Process folderListProcess: Process {
        stdout: StdioCollector { waitForEnd: true }
        onExited: function(code) {
            var out = String(stdout.text || "").trim()
            if (code === 0 && out) {
                var lines = out.split("\n")
                var dirs = []
                var basePath = String(root.folderCurrentPath)
                if (!basePath.endsWith("/")) basePath += "/"
                for (var i = 0; i < lines.length; i++) {
                    var full = String(lines[i]).trim()
                    if (full && full.indexOf(basePath) === 0) {
                        dirs.push(full.substring(basePath.length))
                    } else if (full) {
                        dirs.push(full.replace(/.*\//, ""))
                    }
                }
                root.folderDirs = dirs
            } else {
                root.folderDirs = []
            }
        }
    }

    Rectangle {
        anchors.centerIn: parent
        width: Math.min(Style.space(520), parent.width - Style.gapsOut * 2)
        height: Math.min(parent.height - Style.space(60), Style.space(440))
        color: root.background
        radius: root.cornerRadius
        border.color: Style.normalBorderFor(root.foreground, root.accent)
        border.width: Style.normalBorderWidth

        MouseArea { anchors.fill: parent }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Style.spacing.panelPadding
            spacing: Style.spacing.rowPaddingX

            Text {
                text: "Select Omarchy plugin folder"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Style.spacing.rowGap

                TextField {
                    id: folderPathField
                    Layout.fillWidth: true
                    text: root.folderCurrentPath
                    foreground: root.foreground
                    accent: root.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    activeFocusOnTab: true
                    onEditingFinished: {
                        var t = String(text).trim()
                        if (t) {
                            if (t.charAt(0) !== "/") t = "/" + t
                            root.folderCurrentPath = t
                            root.refreshFolderDirs()
                        }
                    }
                }

                Button {
                    text: "\u2191"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    focusable: true
                    onClicked: root.folderPickerUp()
                }

                Button {
                    text: root.folderShowHidden ? "\u2605" : "\u2606"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    focusable: true
                    onClicked: {
                        root.folderShowHidden = !root.folderShowHidden
                        root.refreshFolderDirs()
                    }
                }
            }

            ListView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                focus: true
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                model: root.folderDirs

                delegate: Rectangle {
                    required property string modelData
                    required property int index

                    width: ListView.view.width
                    implicitHeight: Style.space(36)
                    color: folderDelegateMouse.containsMouse
                        ? Style.hoverFillFor(root.foreground, root.accent)
                        : "transparent"
                    radius: root.cornerRadius - 2

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Style.spacing.controlGap
                        anchors.rightMargin: Style.spacing.controlGap
                        spacing: Style.spacing.rowGap

                        Text {
                            text: "\u25B6"
                            color: Qt.darker(root.foreground, 1.4)
                            font.pixelSize: Style.font.caption
                            Layout.alignment: Qt.AlignVCenter
                        }

                        Text {
                            text: modelData
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.body
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                        }
                    }

                    MouseArea {
                        id: folderDelegateMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton
                        onClicked: {
                            ListView.view.currentIndex = index
                        }
                        onDoubleClicked: {
                            root.folderPickerEnter(modelData)
                        }
                    }
                }

                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: parent.contentHeight + Style.spacing.controlGap
                    visible: parent.count === 0
                    color: "transparent"
                    height: Style.space(32)
                    width: parent.width

                    Text {
                        anchors.centerIn: parent
                        text: "(empty folder)"
                        color: Qt.darker(root.foreground, 1.5)
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                    }
                }
            }

            Row {
                Layout.alignment: Qt.AlignRight
                spacing: Style.spacing.rowGap

                Button {
                    text: "Cancel"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    focusable: true
                    onClicked: root.folderPickerCancel()
                }

                Button {
                    text: "Select this folder"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    focusable: true
                    bordered: true
                    onClicked: root.folderPickerSelect()
                }
            }
        }
    }
}
