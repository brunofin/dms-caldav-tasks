import QtQuick
import qs.Common
import qs.Widgets

Item {
    id: root
    required property var task
    property int depth: 0
    property bool writable: true
    property bool busy: false
    property bool systemTask: false
    signal toggleRequested
    signal editRequested
    signal childRequested
    signal deleteRequested
    readonly property real minimumCardWidth: check.width + actions.width + Theme.spacingXS * 4 + Theme.fontSizeMedium * 6
    implicitHeight: Math.max(Theme.iconSize + Theme.spacingS * 2, title.implicitHeight + Theme.spacingS * 2)

    Rectangle {
        id: card
        x: Math.min(root.depth * (Theme.spacingL + Theme.spacingXXS), Math.max(0, root.width - root.minimumCardWidth))
        width: root.width - x
        height: root.height
        radius: Theme.cornerRadius / 2
        color: hover.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh
        border.width: hover.containsMouse ? 1 : 0
        border.color: Theme.outlineVariant
        Row {
            anchors.fill: parent
            anchors.leftMargin: Theme.spacingXS
            anchors.rightMargin: Theme.spacingXS
            spacing: Theme.spacingXS
            IconAction {
                id: check
                anchors.verticalCenter: parent.verticalCenter
                iconName: root.task.completed ? "check_circle" : "radio_button_unchecked"
                label: root.task.completed ? "Reopen task" : "Complete task"
                enabled: root.writable && !root.busy && !root.task.recurring
                onClicked: root.toggleRequested()
            }
            StyledText {
                id: title
                width: parent.width - check.width - actions.width - Theme.spacingXS * 2
                text: root.task.text
                textFormat: Text.PlainText
                color: root.task.completed ? Theme.surfaceVariantText : Theme.surfaceText
                font.strikeout: root.task.completed
                wrapMode: Text.WordWrap
                anchors.verticalCenter: parent.verticalCenter
            }
            Row {
                id: actions
                anchors.verticalCenter: parent.verticalCenter
                IconAction {
                    iconName: "edit"
                    label: "Edit task"
                    enabled: root.writable && !root.busy && !(root.systemTask && root.task.recurring)
                    onClicked: root.editRequested()
                }
                IconAction {
                    iconName: "subdirectory_arrow_right"
                    label: "Add subtask"
                    enabled: root.writable && !root.busy
                    onClicked: root.childRequested()
                }
                IconAction {
                    iconName: "delete"
                    label: "Delete task"
                    destructive: true
                    enabled: root.writable && !root.busy && !(root.systemTask && root.task.recurring)
                    onClicked: root.deleteRequested()
                }
            }
        }
        MouseArea {
            id: hover
            anchors.fill: parent
            acceptedButtons: Qt.NoButton
            hoverEnabled: true
            z: -1
        }
    }
}
