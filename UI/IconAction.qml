import QtQuick
import QtQuick.Controls
import qs.Common
import qs.Widgets

Rectangle {
    id: root
    property string iconName: ""
    property string label: ""
    property bool destructive: false
    signal clicked
    width: 28
    height: 28
    radius: height / 2
    color: area.containsMouse ? Theme.surfaceContainerHighest : "transparent"
    opacity: enabled ? 1 : 0.35
    activeFocusOnTab: enabled
    Accessible.name: label
    Accessible.role: Accessible.Button
    Keys.onReturnPressed: clicked()
    Keys.onSpacePressed: clicked()
    DankIcon {
        anchors.centerIn: parent
        name: root.iconName
        size: 17
        color: root.destructive ? Theme.error : (area.containsMouse ? Theme.primary : Theme.surfaceVariantText)
    }
    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }
    ToolTip.visible: area.containsMouse && label !== ""
    ToolTip.text: label
    ToolTip.delay: 500
}
