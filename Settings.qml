import QtQuick
import QtQuick.Controls
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "caldavTasks"
    property var sources: []
    property string editingId: ""
    property string provider: "caldav"
    property string message: ""
    property bool confirmingRemoval: false

    function clearForm() {
        editingId = ""
        provider = "caldav"
        nameInput.text = ""
        urlInput.text = ""
        usernameInput.text = ""
        passwordInput.text = ""
        enabledInput.checked = true
        confirmingRemoval = false
    }
    Backend {
        id: backend
        onFinished: data => {
            root.sources = data.sources || []
            root.message = "Connections loaded. Refresh the widget to discover task lists."
            root.clearForm()
        }
        onFailed: message => root.message = message
    }
    Component.onCompleted: backend.run({action: "settings"})

    StyledText {
        text: "CalDAV Tasks"
        color: Theme.surfaceText
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
    }
    StyledText {
        width: parent.width
        text: "Connect directly to CalDAV, or use System accounts (Evolution) for system-managed tasks, including GOA accounts. Only task lists are shown, never calendar events."
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }
    Repeater {
        model: root.sources
        StyledRect {
            width: parent.width
            height: 56
            radius: Theme.cornerRadius
            color: Theme.surfaceContainerHigh
            Row {
                anchors.fill: parent
                anchors.margins: Theme.spacingS
                spacing: Theme.spacingS
                StyledText {
                    width: parent.width - 80
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.name + (modelData.provider === "evolution" ? " · System" : " · CalDAV") + (modelData.enabled ? "" : " (disabled)")
                    color: Theme.surfaceText
                    elide: Text.ElideRight
                }
                DankButton {
                    text: "Edit"
                    enabled: !backend.busy
                    onClicked: {
                        root.editingId = modelData.id
                        root.provider = modelData.provider || "caldav"
                        nameInput.text = modelData.name
                        urlInput.text = modelData.url || ""
                        usernameInput.text = modelData.username || ""
                        passwordInput.text = ""
                        enabledInput.checked = modelData.enabled
                        root.confirmingRemoval = false
                    }
                }
            }
        }
    }
    StyledRect {
        width: parent.width
        height: form.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh
        Column {
            id: form
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingS
            enabled: !backend.busy
            StyledText {
                text: root.editingId ? "Edit connection" : "New connection"
                color: Theme.surfaceText
                font.weight: Font.Medium
            }
            DankDropdown {
                width: parent.width
                dropdownWidth: width
                options: ["Direct CalDAV", "System accounts (Evolution)"]
                currentValue: root.provider === "evolution" ? options[1] : options[0]
                enabled: root.editingId === ""
                onValueChanged: value => {
                    root.provider = value === options[1] ? "evolution" : "caldav"
                    if (root.provider === "evolution" && !nameInput.text.trim())
                        nameInput.text = "System accounts (Evolution)"
                }
            }
            DankTextField { id: nameInput; width: parent.width; placeholderText: "Connection name (Personal, Work…)" }
            StyledText {
                width: parent.width
                visible: root.provider === "evolution"
                text: "EDS discovers enabled task sources automatically, including Google Tasks, CalDAV and local lists. Credentials and OAuth stay with the system. List management remains in Evolution; task editing depends on the source’s permissions."
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
            }
            DankTextField { id: urlInput; visible: root.provider === "caldav"; width: parent.width; placeholderText: "https://server.example/caldav/" }
            DankTextField { id: usernameInput; visible: root.provider === "caldav"; width: parent.width; placeholderText: "Username" }
            DankTextField {
                id: passwordInput
                visible: root.provider === "caldav"
                width: parent.width
                placeholderText: root.editingId ? "App password (blank keeps existing)" : "App password"
                echoMode: TextInput.Password
            }
            CheckBox { id: enabledInput; text: "Enabled"; checked: true }
            Row {
                spacing: Theme.spacingS
                DankButton {
                    text: "Save connection"
                    onClicked: backend.run({action: "save_source", source: {
                        id: root.editingId, provider: root.provider, name: nameInput.text, url: urlInput.text,
                        username: usernameInput.text, password: passwordInput.text,
                        enabled: enabledInput.checked
                    }})
                }
                DankButton { text: "New / Cancel"; onClicked: root.clearForm() }
            }
            DankButton {
                visible: root.editingId !== ""
                text: root.confirmingRemoval ? "Confirm disconnect (server tasks are kept)" : "Disconnect account"
                onClicked: {
                    if (root.confirmingRemoval)
                        backend.run({action: "remove_source", sourceId: root.editingId})
                    else
                        root.confirmingRemoval = true
                }
            }
        }
    }
    StyledText {
        width: parent.width
        text: backend.busy ? "Working…" : root.message
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }
    StringSetting {
        settingKey: "refreshSeconds"
        label: "Refresh interval (seconds)"
        description: "Minimum 30 seconds; default 120. Opening the widget also refreshes."
        defaultValue: "120"
    }
    StyledText {
        width: parent.width
        text: "Direct CalDAV: TLS certificates are always verified. Credentials are stored in $XDG_CONFIG_HOME/dms-caldav-tasks/connections.json (mode 0600), not DMS settings or process arguments. This file is not encrypted; exclude it from dotfile repositories. System accounts: only the provider selection is saved here; EDS manages authentication and caching."
        color: Theme.surfaceVariantText
        font.pixelSize: Theme.fontSizeSmall
        wrapMode: Text.WordWrap
    }
}
