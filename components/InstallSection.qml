import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Rectangle {
    id: root

    Layout.fillWidth: true
    implicitHeight: installColumn.implicitHeight + Style.spacing.rowPaddingX * 2
    radius: root.cornerRadius
    color: Style.normalFillFor(root.foreground, root.accent)
    border.color: Style.normalBorderFor(root.foreground, root.accent)
    border.width: Style.normalBorderWidth

    property color foreground: Commons.Color.foreground
    property color accent: Commons.Color.accent
    property color urgent: Commons.Color.urgent
    property string fontFamily: Style.font.family
    property int cornerRadius: Style.cornerRadius

    property string installMode: "source"
    property string localPluginPath: ""
    property string localPluginStatus: ""
    property string newSourceUrl: ""
    property string onlineInstallStatus: ""

    property bool installLocalBusy: false
    property bool installFromSourceBusy: false

    signal installLocalRequested(string path)
    signal browseRequested()
    signal installFromSourceRequested(string url)

    ColumnLayout {
        id: installColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.spacing.rowPaddingX
        anchors.rightMargin: Style.spacing.rowPaddingX
        spacing: Style.spacing.labelGap

        Text {
            text: "Install"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            Layout.fillWidth: true
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.labelGap

            Button {
                text: "Source"
                foreground: root.foreground
                fontFamily: root.fontFamily
                focusable: true
                bordered: root.installMode !== "source"
                selected: root.installMode === "source"
                onClicked: root.installMode = "source"
            }

            Button {
                text: "Local"
                foreground: root.foreground
                fontFamily: root.fontFamily
                focusable: true
                bordered: root.installMode !== "local"
                selected: root.installMode === "local"
                onClicked: root.installMode = "local"
            }

            Item { Layout.fillWidth: true; implicitHeight: 1 }
        }

        ColumnLayout {
            Layout.fillWidth: true
            visible: root.installMode === "local"
            spacing: Style.spacing.labelGap

            RowLayout {
                Layout.fillWidth: true
                spacing: Style.spacing.rowGap

                TextField {
                    Layout.fillWidth: true
                    text: root.localPluginPath
                    placeholderText: "/path/to/plugin-folder"
                    foreground: root.foreground
                    accent: root.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    activeFocusOnTab: true
                    onTextEdited: root.localPluginPath = text
                    onAccepted: root.installLocalRequested(text)
                }

                Button {
                    text: "Browse"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    focusable: true
                    bordered: true
                    onClicked: root.browseRequested()
                }

                Button {
                    text: "Install"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    focusable: true
                    bordered: true
                    enabled: !root.installLocalBusy
                    onClicked: root.installLocalRequested(root.localPluginPath)
                }
            }

            Text {
                visible: root.localPluginStatus !== ""
                text: root.localPluginStatus
                color: root.localPluginStatus.indexOf("failed") !== -1 || root.localPluginStatus.indexOf("Invalid") !== -1 || root.localPluginStatus.indexOf("not") !== -1
                    ? root.urgent
                    : Qt.darker(root.foreground, 1.5)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            visible: root.installMode === "source"
            spacing: Style.spacing.labelGap

            Text {
                text: "Paste the git URL of a plugin repo to install it. Plugins land disabled so you can review the code before enabling them."
                color: Qt.darker(root.foreground, 1.5)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Style.spacing.rowGap

                TextField {
                    Layout.fillWidth: true
                    text: root.newSourceUrl
                    placeholderText: "https://github.com/owner/omarchy-weather.git"
                    foreground: root.foreground
                    accent: root.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    activeFocusOnTab: true
                    onTextEdited: root.newSourceUrl = text
                    onAccepted: root.installFromSourceRequested(text)
                }

                Button {
                    text: "Install"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    focusable: true
                    bordered: true
                    enabled: !root.installFromSourceBusy
                    onClicked: root.installFromSourceRequested(root.newSourceUrl)
                }
            }

            Text {
                visible: root.onlineInstallStatus !== ""
                text: root.onlineInstallStatus
                color: root.onlineInstallStatus.indexOf("failed") !== -1 || root.onlineInstallStatus.indexOf("Failed") !== -1
                    ? root.urgent
                    : Qt.darker(root.foreground, 1.5)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
        }
    }
}
