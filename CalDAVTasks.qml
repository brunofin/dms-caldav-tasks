import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import "UI" as TaskUi

PluginComponent {
    id: root
    popoutWidth: 480

    property var sources: []
    property var lists: []
    property var todos: []
    property string filter: "active"
    property string errorMessage: ""
    // These are transient action targets, never a selected source/list or view filter.
    property var composer: null
    property string draftText: ""
    property var listOperation: null
    property string listDraft: ""
    property var pendingDelete: null
    property string submitting: ""
    property var collapsedGroups: ({sources: [], lists: []})
    signal focusComposer
    signal revealSource(string sourceId)

    readonly property bool busy: backend.busy
    readonly property int maxTextLength: 2000
    readonly property var knownTodos: todos.filter(t => lists.some(l => l.id === t.listId) && sources.some(s => s.id === t.sourceId))
    readonly property int visibleCount: knownTodos.length
    readonly property int activeCount: knownTodos.filter(t => !t.completed).length
    readonly property int doneCount: visibleCount - activeCount
    readonly property var openTaskCounts: {
        const counts = {sources: Object.create(null), lists: Object.create(null)}
        for (const task of knownTodos) {
            if (task.completed) continue
            counts.sources[task.sourceId] = (counts.sources[task.sourceId] || 0) + 1
            counts.lists[task.listId] = (counts.lists[task.listId] || 0) + 1
        }
        return counts
    }
    readonly property var sortedSources: sources.slice().sort((a, b) =>
        (openTaskCounts.sources[b.id] || 0) - (openTaskCounts.sources[a.id] || 0) || compareGroupNames(a, b))
    readonly property var displayRows: buildRows()
    readonly property var connectionSummary: sortedSources.map(source => ({
        id: source.id, name: source.name,
        lists: lists.filter(list => list.sourceId === source.id).length,
        tasks: knownTodos.filter(task => task.sourceId === source.id).length
    }))

    function compareGroupNames(a, b) {
        return String(a.listName || a.name || "").toLocaleLowerCase().localeCompare(String(b.listName || b.name || "").toLocaleLowerCase()) ||
            String(a.accountName || "").localeCompare(String(b.accountName || "")) || String(a.id).localeCompare(String(b.id))
    }
    function sortedListsForSource(id) {
        return lists.filter(list => list.sourceId === id).sort((a, b) =>
            (openTaskCounts.lists[b.id] || 0) - (openTaskCounts.lists[a.id] || 0) || compareGroupNames(a, b))
    }

    function sourceRowIndex(id) { return displayRows.findIndex(row => row.kind === "source" && row.source.id === id) }
    function isSourceCollapsed(id) { return collapsedGroups.sources.includes(id) }
    function isListCollapsed(id) { return collapsedGroups.lists.includes(id) }
    function loadCollapseState() {
        if (!pluginService || typeof pluginService.loadPluginState !== "function") return
        const saved = pluginService.loadPluginState("caldavTasks", "collapsedGroups", {}) || {}
        function ids(value) { return Array.isArray(value) ? [...new Set(value.filter(id => typeof id === "string"))] : [] }
        const state = {sources: ids(saved.sources), lists: ids(saved.lists)}
        if (JSON.stringify(state) !== JSON.stringify(collapsedGroups)) collapsedGroups = state
    }
    function saveCollapseState() {
        if (pluginService && typeof pluginService.savePluginState === "function")
            pluginService.savePluginState("caldavTasks", "collapsedGroups", collapsedGroups)
    }
    function setGroupCollapsed(kind, id, collapsed) {
        if (kind !== "sources" && kind !== "lists") return
        if (collapsedGroups[kind].includes(id) === collapsed) return
        const next = {sources: collapsedGroups.sources.slice(), lists: collapsedGroups.lists.slice()}
        next[kind] = collapsed ? next[kind].concat([id]) : next[kind].filter(value => value !== id)
        collapsedGroups = next
        saveCollapseState()
    }
    function toggleSource(id) {
        if (sources.some(source => source.id === id)) setGroupCollapsed("sources", id, !isSourceCollapsed(id))
    }
    function toggleList(id) {
        if (listById(id)) setGroupCollapsed("lists", id, !isListCollapsed(id))
    }
    function expandList(id) {
        const list = listById(id)
        if (!list) return
        const state = {sources: collapsedGroups.sources.filter(value => value !== list.sourceId),
                       lists: collapsedGroups.lists.filter(value => value !== id)}
        if (JSON.stringify(state) !== JSON.stringify(collapsedGroups)) {
            collapsedGroups = state
            saveCollapseState()
        }
    }
    Connections {
        target: root
        function onPluginServiceChanged() { root.loadCollapseState() }
    }
    Connections {
        target: root.pluginService
        function onPluginStateChanged(pluginId) { if (pluginId === "caldavTasks") root.loadCollapseState() }
    }

    function parseIntOr(value, fallback, min) {
        const n = parseInt(value, 10)
        return isNaN(n) ? fallback : Math.max(min, n)
    }
    function listById(id) { return lists.find(l => l.id === id) || null }
    function listWritable(id) {
        const list = listById(id)
        return list !== null && !list.readOnly && sources.some(s => s.id === list.sourceId)
    }
    function filteredTodos(filterKey, listId) {
        const items = knownTodos.filter(t => !listId || t.listId === listId)
        if (filterKey === "active") return items.filter(t => !t.completed && !hasCompletedAncestor(t.id))
        if (filterKey === "done") return items.filter(t => t.completed)
        return items
    }
    function hasCompletedAncestor(id) {
        let task = todos.find(t => t.id === id)
        for (let n = 0; task && task.parentId && n < 32; n++) {
            task = todos.find(t => t.id === task.parentId)
            if (task && task.completed) return true
        }
        return false
    }
    function depthOf(id) {
        let task = todos.find(t => t.id === id)
        let depth = 0
        while (task && task.parentId && depth < 16) {
            task = todos.find(t => t.id === task.parentId)
            if (task) depth++
        }
        return depth
    }
    function buildRows() {
        const rows = []
        for (const source of sortedSources) {
            rows.push({kind: "source", source: source})
            if (isSourceCollapsed(source.id)) continue
            const sourceLists = sortedListsForSource(source.id)
            if (sourceLists.length === 0)
                rows.push({kind: "empty", text: "No task lists available"})
            for (const list of sourceLists) {
                rows.push({kind: "list", list: list})
                if (isListCollapsed(list.id)) continue
                if (composer && composer.listId === list.id)
                    rows.push({kind: "composer", list: list})
                const tasks = filteredTodos(filter, list.id)
                for (const task of tasks)
                    rows.push({kind: "task", task: task, list: list, source: source})
                if (tasks.length === 0)
                    rows.push({kind: "empty", text: filter === "active" ? "No active tasks" : filter === "done" ? "No completed tasks" : "No tasks yet"})
            }
        }
        return rows
    }
    function run(action, fields) {
        if (busy) return false
        errorMessage = ""
        return backend.run(Object.assign({action: action}, fields || {}))
    }
    function reloadTodos() { if (!busy) run("sync") }
    function cancelComposer() { composer = null; draftText = "" }
    function beginComposer(listId, editingId, parentId) {
        if (busy || !listWritable(listId)) return false
        const list = listById(listId)
        const targetId = editingId || parentId
        const task = targetId ? todos.find(t => t.id === targetId && t.listId === listId) : null
        if (targetId && !task) return false
        expandList(listId)
        draftText = editingId ? task.text : ""
        composer = {sourceId: list.sourceId, listId: listId, editingId: editingId || "", parentId: parentId || "", label: task ? task.text : ""}
        return true
    }
    function addTodo(text, listId, parentId) {
        const trimmed = String(text || "").trim()
        if (!trimmed || !listWritable(listId)) return false
        const list = listById(listId)
        if (parentId && !todos.some(t => t.id === parentId && t.listId === listId)) return false
        return run("add_task", {sourceId: list.sourceId, listId: listId, text: trimmed, parentId: parentId || null})
    }
    function editTodo(id, text) {
        const task = todos.find(t => t.id === id)
        const trimmed = String(text || "").trim()
        if (!task || !trimmed || !listWritable(task.listId)) return false
        return run("edit_task", {sourceId: task.sourceId, listId: task.listId, id: id, text: trimmed})
    }
    function submitComposer() {
        if (!composer || busy) return false
        const ok = composer.editingId ? editTodo(composer.editingId, draftText) : addTodo(draftText, composer.listId, composer.parentId)
        if (ok) submitting = "composer"
        return ok
    }
    function toggleTodo(id) {
        const task = todos.find(t => t.id === id)
        if (task && listWritable(task.listId))
            return run("set_completed", {sourceId: task.sourceId, listId: task.listId, id: id, completed: !task.completed})
        return false
    }
    function deleteTodo(id) {
        const task = todos.find(t => t.id === id)
        if (task && listWritable(task.listId)) pendingDelete = task
    }
    function startListOperation(action, sourceId, listId) {
        const source = sources.find(s => s.id === sourceId)
        const list = listId ? listById(listId) : null
        if (busy || !source) return false
        if (action === "create_list" ? source.canCreateLists === false :
            !list || list.sourceId !== sourceId || !listWritable(listId) || (action === "rename_list" ? list.canRename === false : list.canDelete === false)) return false
        listDraft = action === "rename_list" ? list.name : ""
        listOperation = {action: action, sourceId: sourceId, listId: listId || "", name: list ? list.name : source.name}
        return true
    }
    function pillCountLabel() {
        switch (String(pluginData.countMode || "active")) {
        case "total": return String(visibleCount)
        case "done": return String(doneCount)
        case "hidden": return ""
        default: return String(activeCount)
        }
    }

    Backend {
        id: backend
        onFailed: message => { root.errorMessage = message; root.submitting = "" }
        onFinished: data => {
            if (data.changed) {
                if (root.submitting === "composer") root.cancelComposer()
                if (root.submitting === "list") root.listOperation = null
                if (root.submitting === "delete") root.pendingDelete = null
                root.submitting = ""
                Qt.callLater(root.reloadTodos)
                return
            }
            if (!data.todos) return
            const enabled = data.sources.filter(s => s.enabled).map(s => s.id)
            const good = data.successfulSources
            const failed = data.failedLists || []
            root.todos = root.todos.filter(t => enabled.includes(t.sourceId) && (!good.includes(t.sourceId) || failed.includes(t.listId))).concat(data.todos)
            root.lists = root.lists.filter(l => enabled.includes(l.sourceId) && !good.includes(l.sourceId)).map(l => Object.assign({}, l, {readOnly: true})).concat(data.lists)
            root.sources = data.sources.filter(s => s.enabled)
            root.errorMessage = data.errors.map(e => {
                const source = data.sources.find(s => s.id === e.sourceId)
                return (source ? source.name : "Source") + ": " + e.message
            }).join("\n")
            if (root.composer && (!root.listById(root.composer.listId) ||
                (root.composer.editingId && !root.todos.some(t => t.id === root.composer.editingId)) ||
                (root.composer.parentId && !root.todos.some(t => t.id === root.composer.parentId)))) root.cancelComposer()
            if (root.pendingDelete && !root.todos.some(t => t.id === root.pendingDelete.id)) root.pendingDelete = null
            if (root.listOperation && (!root.sources.some(s => s.id === root.listOperation.sourceId) ||
                (root.listOperation.listId && !root.listById(root.listOperation.listId)))) root.listOperation = null
        }
    }
    Timer {
        interval: root.parseIntOr(root.pluginData.refreshSeconds, 120, 30) * 1000
        repeat: true
        running: true
        onTriggered: root.reloadTodos()
    }
    IpcHandler {
        target: "caldavTasks"
        function refresh(): string { root.reloadTodos(); return "QUEUED" }
        function list(): string { return JSON.stringify(root.filteredTodos("all")) }
        function count(): string { return root.activeCount + "/" + root.visibleCount }
        function status(): string {
            return JSON.stringify({loading: root.busy, connections: root.sources.length, lists: root.lists.length,
                                   active: root.activeCount, total: root.visibleCount, error: root.errorMessage})
        }
    }
    Component.onCompleted: { loadCollapseState(); Qt.callLater(root.reloadTodos) }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS
            DankIcon {
                name: root.activeCount > 0 ? "checklist" : "check_circle"
                size: Theme.iconSize - 6
                color: root.activeCount > 0 ? Theme.primary : Theme.surfaceVariantText
                anchors.verticalCenter: parent.verticalCenter
            }
            StyledText {
                text: root.pillCountLabel()
                visible: text.length > 0
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }
    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS
            DankIcon { name: "checklist"; size: Theme.iconSize - 6; color: Theme.primary; anchors.horizontalCenter: parent.horizontalCenter }
            StyledText { text: root.pillCountLabel(); visible: text.length > 0; color: Theme.surfaceVariantText; anchors.horizontalCenter: parent.horizontalCenter }
        }
    }

    popoutContent: Component {
        PopoutComponent {
            id: popout
            width: 440
            headerText: "Tasks"
            detailsText: root.activeCount + " active · " + root.doneCount + " done · " + root.sources.length + " connections · " + root.lists.length + " lists"
            showCloseButton: true
            headerActions: Component {
                TaskUi.IconAction { iconName: "refresh"; label: "Refresh all connections"; enabled: !root.busy; onClicked: root.reloadTodos() }
            }
            onVisibleChanged: { if (visible) root.reloadTodos() }

            Column {
                width: parent.width
                spacing: Theme.spacingS
                Flow {
                    id: connections
                    width: parent.width
                    spacing: Theme.spacingXS
                    Repeater {
                        model: root.connectionSummary
                        Rectangle {
                            width: Math.min(connections.width, connectionLabel.implicitWidth + Theme.spacingM * 2)
                            height: 32
                            radius: Theme.cornerRadius
                            color: jumpArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh
                            border.width: 1
                            border.color: Theme.outlineVariant
                            activeFocusOnTab: true
                            Accessible.name: "Jump to " + modelData.name
                            Accessible.role: Accessible.Button
                            Keys.onReturnPressed: root.revealSource(modelData.id)
                            Keys.onSpacePressed: root.revealSource(modelData.id)
                            StyledText {
                                id: connectionLabel
                                anchors.centerIn: parent
                                width: Math.min(implicitWidth, parent.width - Theme.spacingM * 2)
                                text: modelData.name + " · " + modelData.lists + " lists"
                                textFormat: Text.PlainText
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceText
                                elide: Text.ElideRight
                            }
                            MouseArea {
                                id: jumpArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.revealSource(modelData.id)
                            }
                            ToolTip.visible: jumpArea.containsMouse
                            ToolTip.text: "Expand and jump to " + modelData.name + ". Other connections are not filtered out."
                        }
                    }
                }
                Row {
                    id: filters
                    width: parent.width
                    spacing: Theme.spacingXS
                    Repeater {
                        model: [{key: "active", label: "Active", count: root.activeCount}, {key: "all", label: "All", count: root.visibleCount}, {key: "done", label: "Done", count: root.doneCount}]
                        Rectangle {
                            width: (filters.width - filters.spacing * 2) / 3
                            height: 30
                            radius: Theme.cornerRadius
                            color: root.filter === modelData.key ? Theme.primary : Theme.surfaceContainerHigh
                            StyledText {
                                anchors.centerIn: parent
                                text: modelData.label + " (" + modelData.count + ")"
                                font.pixelSize: Theme.fontSizeSmall
                                color: root.filter === modelData.key ? Theme.onPrimary : Theme.surfaceText
                            }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.filter = modelData.key }
                        }
                    }
                }
                StyledText {
                    width: parent.width
                    visible: root.busy || root.errorMessage !== "" || root.sources.length === 0
                    text: root.busy ? "Syncing…" : (root.errorMessage || "Add a connection in this plugin’s settings.")
                    textFormat: Text.PlainText
                    color: root.errorMessage ? Theme.error : Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                    font.pixelSize: Theme.fontSizeSmall
                }
                Column {
                    width: parent.width
                    spacing: Theme.spacingXS
                    visible: root.listOperation !== null
                    StyledText {
                        width: parent.width
                        text: !root.listOperation ? "" : root.listOperation.action === "delete_list" ? "Delete “" + root.listOperation.name + "” and ALL its tasks? Type its exact name to confirm." : (root.listOperation.action === "create_list" ? "New list in " : "Rename ") + root.listOperation.name
                        textFormat: Text.PlainText
                        wrapMode: Text.WordWrap
                        color: Theme.surfaceText
                    }
                    DankTextField { width: parent.width; text: root.listDraft; onTextEdited: root.listDraft = text; enabled: !root.busy }
                    Row {
                        spacing: Theme.spacingS
                        DankButton {
                            text: root.listOperation && root.listOperation.action === "delete_list" ? "Delete permanently" : "Save list"
                            enabled: !root.busy && root.listDraft.trim() !== "" && root.listOperation !== null &&
                                (root.listOperation.action !== "delete_list" || root.listDraft === root.listOperation.name)
                            onClicked: { if (root.run(root.listOperation.action, Object.assign({}, root.listOperation, {text: root.listDraft, confirm: root.listDraft}))) root.submitting = "list" }
                        }
                        DankButton { text: "Cancel"; enabled: !root.busy; onClicked: root.listOperation = null }
                    }
                }
                Column {
                    width: parent.width
                    spacing: Theme.spacingXS
                    visible: root.pendingDelete !== null
                    StyledText {
                        width: parent.width
                        text: root.pendingDelete ? "Permanently delete “" + root.pendingDelete.text + "”? " + (root.pendingDelete.recurring ? "This removes its recurrence series. " : "") + "Subtasks will remain." : ""
                        textFormat: Text.PlainText
                        color: Theme.error
                        wrapMode: Text.WordWrap
                    }
                    Row {
                        spacing: Theme.spacingS
                        DankButton {
                            text: "Delete task"
                            enabled: !root.busy && root.pendingDelete !== null && root.listWritable(root.pendingDelete.listId)
                            onClicked: { if (root.run("delete_task", Object.assign({}, root.pendingDelete, {confirm: true}))) root.submitting = "delete" }
                        }
                        DankButton { text: "Cancel"; enabled: !root.busy; onClicked: root.pendingDelete = null }
                    }
                }

                ListView {
                    id: groupedList
                    objectName: "groupedTaskList"
                    width: parent.width
                    height: Math.min(440, Math.max(64, contentHeight))
                    clip: true
                    spacing: Theme.spacingXS
                    model: root.displayRows
                    ScrollBar.vertical: ScrollBar {
                        id: scrollBar
                        policy: ScrollBar.AlwaysOn
                        active: true
                        width: 8
                        minimumSize: 0.08
                        contentItem: Rectangle { radius: width / 2; color: Theme.primary; opacity: scrollBar.pressed ? 1 : 0.7 }
                        background: Rectangle { radius: width / 2; color: Theme.surfaceContainerHighest }
                    }
                    Connections {
                        target: root
                        function onRevealSource(sourceId) {
                            root.setGroupCollapsed("sources", sourceId, false)
                            Qt.callLater(() => {
                                const index = root.sourceRowIndex(sourceId)
                                if (index >= 0) groupedList.positionViewAtIndex(index, ListView.Beginning)
                            })
                        }
                        function onComposerChanged() {
                            if (!root.composer) return
                            Qt.callLater(() => {
                                const index = root.displayRows.findIndex(row => row.kind === "composer")
                                if (index >= 0) groupedList.positionViewAtIndex(index, ListView.Contain)
                                root.focusComposer()
                            })
                        }
                    }
                    delegate: Loader {
                        id: rowLoader
                        required property var modelData
                        readonly property var row: modelData
                        width: groupedList.width - (scrollBar.visible ? scrollBar.width + Theme.spacingS : 0)
                        height: item ? item.implicitHeight : 0
                        sourceComponent: row.kind === "source" ? sourceHeading : row.kind === "list" ? listHeading : row.kind === "task" ? taskRow : row.kind === "composer" ? composerRow : emptyRow

                        Component {
                            id: sourceHeading
                            Item {
                                implicitHeight: 62
                                TaskUi.IconAction {
                                    id: sourceChevron
                                    anchors.left: parent.left
                                    anchors.verticalCenter: parent.verticalCenter
                                    iconName: root.isSourceCollapsed(rowLoader.row.source.id) ? "chevron_right" : "expand_more"
                                    label: (root.isSourceCollapsed(rowLoader.row.source.id) ? "Expand " : "Collapse ") + rowLoader.row.source.name
                                    onClicked: root.toggleSource(rowLoader.row.source.id)
                                }
                                Column {
                                    id: sourceLabels
                                    anchors.left: sourceChevron.right
                                    anchors.leftMargin: Theme.spacingXS
                                    anchors.right: newList.left
                                    anchors.rightMargin: Theme.spacingS
                                    anchors.verticalCenter: parent.verticalCenter
                                    StyledText { width: parent.width; text: rowLoader.row.source.name; textFormat: Text.PlainText; color: Theme.primary; font.pixelSize: Theme.fontSizeLarge; font.weight: Font.Bold; elide: Text.ElideRight }
                                    StyledText { text: (rowLoader.row.source.provider === "evolution" ? "SYSTEM ACCOUNTS · EVOLUTION" : "DIRECT CALDAV") + " · " + root.lists.filter(list => list.sourceId === rowLoader.row.source.id).length + " lists"; color: Theme.surfaceVariantText; font.pixelSize: Theme.fontSizeSmall * 0.8 }
                                }
                                MouseArea {
                                    anchors.fill: sourceLabels
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.toggleSource(rowLoader.row.source.id)
                                }
                                TaskUi.IconAction {
                                    id: newList
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: rowLoader.row.source.canCreateLists !== false
                                    enabled: !root.busy
                                    iconName: "create_new_folder"
                                    label: "New list in " + rowLoader.row.source.name
                                    onClicked: root.startListOperation("create_list", rowLoader.row.source.id, "")
                                }
                            }
                        }
                        Component {
                            id: listHeading
                            Item {
                                implicitHeight: 56
                                TaskUi.IconAction {
                                    id: listChevron
                                    anchors.left: parent.left
                                    anchors.verticalCenter: parent.verticalCenter
                                    iconName: root.isListCollapsed(rowLoader.row.list.id) ? "chevron_right" : "expand_more"
                                    label: (root.isListCollapsed(rowLoader.row.list.id) ? "Expand " : "Collapse ") + (rowLoader.row.list.listName || rowLoader.row.list.name)
                                    onClicked: root.toggleList(rowLoader.row.list.id)
                                }
                                Column {
                                    id: listLabels
                                    anchors.left: listChevron.right
                                    anchors.leftMargin: Theme.spacingXS
                                    anchors.right: listActions.left
                                    anchors.rightMargin: Theme.spacingS
                                    anchors.verticalCenter: parent.verticalCenter
                                    StyledText { width: parent.width; text: rowLoader.row.list.listName || rowLoader.row.list.name; textFormat: Text.PlainText; color: Theme.surfaceText; font.pixelSize: Theme.fontSizeMedium; font.weight: Font.DemiBold; elide: Text.ElideRight }
                                    StyledText { width: parent.width; text: (rowLoader.row.list.accountName ? rowLoader.row.list.accountName + " · " : "") + root.filteredTodos("active", rowLoader.row.list.id).length + " active" + (rowLoader.row.list.readOnly ? " · Read-only / unavailable" : ""); textFormat: Text.PlainText; color: Theme.surfaceVariantText; font.pixelSize: Theme.fontSizeSmall; elide: Text.ElideRight }
                                }
                                MouseArea {
                                    anchors.fill: listLabels
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.toggleList(rowLoader.row.list.id)
                                }
                                Row {
                                    id: listActions
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    TaskUi.IconAction { iconName: "edit"; label: "Rename list"; visible: rowLoader.row.list.canRename !== false; enabled: !root.busy && root.listWritable(rowLoader.row.list.id); onClicked: root.startListOperation("rename_list", rowLoader.row.list.sourceId, rowLoader.row.list.id) }
                                    TaskUi.IconAction { iconName: "delete"; label: "Delete list"; destructive: true; visible: rowLoader.row.list.canDelete === true; enabled: !root.busy && root.listWritable(rowLoader.row.list.id); onClicked: root.startListOperation("delete_list", rowLoader.row.list.sourceId, rowLoader.row.list.id) }
                                    TaskUi.IconAction { iconName: "add"; label: "Add task to this list"; enabled: !root.busy && root.listWritable(rowLoader.row.list.id); onClicked: root.beginComposer(rowLoader.row.list.id, "", "") }
                                }
                            }
                        }
                        Component {
                            id: taskRow
                            TaskUi.TaskCard {
                                task: rowLoader.row.task
                                depth: root.depthOf(task.id)
                                writable: root.listWritable(task.listId)
                                busy: root.busy
                                systemTask: rowLoader.row.source.provider === "evolution"
                                onToggleRequested: root.toggleTodo(task.id)
                                onEditRequested: root.beginComposer(task.listId, task.id, "")
                                onChildRequested: root.beginComposer(task.listId, "", task.id)
                                onDeleteRequested: root.deleteTodo(task.id)
                            }
                        }
                        Component {
                            id: composerRow
                            Column {
                                spacing: Theme.spacingXS
                                StyledText {
                                    id: composerLabel
                                    width: parent.width
                                    text: !root.composer ? "" : (root.composer.editingId ? "Editing: " : root.composer.parentId ? "Subtask of: " : "Add to: ") + (root.composer.label || rowLoader.row.list.name)
                                    textFormat: Text.PlainText
                                    color: Theme.primary
                                    font.pixelSize: Theme.fontSizeSmall
                                    elide: Text.ElideRight
                                }
                                Row {
                                    id: inputRow
                                    width: parent.width
                                    height: input.height
                                    spacing: Theme.spacingXS
                                    enabled: !root.busy && root.listWritable(rowLoader.row.list.id)
                                    DankTextField {
                                        id: input
                                        width: parent.width - submit.width - cancel.width - Theme.spacingXS * 2
                                        text: root.draftText
                                        placeholderText: "Task title and Enter"
                                        maximumLength: root.maxTextLength
                                        onTextEdited: root.draftText = text
                                        onAccepted: root.submitComposer()
                                        Keys.onEscapePressed: root.cancelComposer()
                                        Component.onCompleted: forceActiveFocus()
                                        Connections { target: root; function onFocusComposer() { input.forceActiveFocus() } }
                                    }
                                    TaskUi.IconAction { id: submit; anchors.verticalCenter: parent.verticalCenter; iconName: "check"; label: "Save task"; enabled: root.draftText.trim() !== ""; onClicked: root.submitComposer() }
                                    TaskUi.IconAction { id: cancel; anchors.verticalCenter: parent.verticalCenter; iconName: "close"; label: "Cancel"; onClicked: root.cancelComposer() }
                                }
                            }
                        }
                        Component {
                            id: emptyRow
                            Item {
                                implicitHeight: 28
                                StyledText { anchors.fill: parent; text: rowLoader.row.text || ""; color: Theme.surfaceVariantText; font.pixelSize: Theme.fontSizeSmall; leftPadding: Theme.spacingS; verticalAlignment: Text.AlignVCenter }
                            }
                        }
                    }
                }
            }
        }
    }
}
