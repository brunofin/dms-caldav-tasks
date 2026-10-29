import QtQuick
import qs.Common
import qs.Widgets

Rectangle {
    id: root
    property string iconName: ""
    property string label: ""
    property bool destructive: false
    signal clicked
    width: Theme.iconSize + Theme.spacingXS
    height: width
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
        size: Theme.iconSizeSmall
        color: root.destructive ? Theme.error : (area.containsMouse ? Theme.primary : Theme.surfaceVariantText)
    }
    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onEntered: { if (root.label) tooltip.show(root.label, root) }
        onExited: tooltip.hide()
        onPressed: tooltip.hide()
        onClicked: root.clicked()
    }
    DankTooltipV2 { id: tooltip; objectName: "actionTooltip" }
    onVisibleChanged: { if (!visible) tooltip.hide() }
    onEnabledChanged: { if (!enabled) tooltip.hide() }
}
