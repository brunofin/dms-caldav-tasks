import QtQuick
import QtQuick.Window
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

ShellRoot {
    id: root
    property var widget: null
    property var settings: null
    property var popout: null
    property var pill: null
    property var restoredWidget: null
    property bool fixturesTested: false
    QtObject {
        id: stateService
        property var savedState: ({})
        signal pluginStateChanged(string pluginId)
        signal pluginDataChanged(string pluginId)
        function getPluginVariants(pluginId) { return [] }
        function loadPluginState(pluginId, key, fallback) {
            return savedState[key] === undefined ? fallback : JSON.parse(JSON.stringify(savedState[key]))
        }
        function savePluginState(pluginId, key, value) {
            const next = Object.assign({}, savedState)
            next[key] = JSON.parse(JSON.stringify(value))
            savedState = next
            pluginStateChanged(pluginId)
        }
    }
    Window {
        id: scene
        visible: Quickshell.env("CALDAV_TASKS_SCREENSHOT") !== ""
        title: "CalDAV Tasks preview"
        width: 500
        height: 660
        color: Theme.surfaceContainer
        Rectangle { anchors.fill: parent; color: Theme.surfaceContainer; z: -1 }
    }
    Component.onCompleted: {
        const base = Quickshell.env("CALDAV_TASKS_PROJECT") + "/"
        const widgetComponent = Qt.createComponent("file://" + base + "CalDAVTasks.qml")
        if (widgetComponent.status !== Component.Ready) {
            console.error("SMOKE FAILURE: " + widgetComponent.errorString())
            Qt.quit()
            return
        }
        widget = widgetComponent.createObject(scene.contentItem, {pluginService: stateService})
        if (!widget) { console.error("SMOKE FAILURE: widget creation"); Qt.quit(); return }
        popout = widget.popoutContent.createObject(scene.contentItem)
        pill = widget.horizontalBarPill.createObject(scene.contentItem)
        const settingsComponent = Qt.createComponent("file://" + base + "Settings.qml")
        if (settingsComponent.status !== Component.Ready) {
            console.error("SMOKE FAILURE: " + settingsComponent.errorString())
            Qt.quit()
            return
        }
        settings = settingsComponent.createObject(scene.contentItem)
        if (settings) settings.visible = false
        if (pill) pill.visible = false
        if (popout) { popout.x = 12; popout.y = 12 }
        if (!popout || !pill || !settings) console.error("SMOKE FAILURE: UI creation")
        else console.warn("SMOKE UI CREATED")
    }
    Timer {
        interval: 1800
        running: true
        onTriggered: {
            if (!root.widget || root.widget.busy) return
            root.widget.sources = [{id: "one", name: "System", provider: "evolution", canCreateLists: false},
                                   {id: "two", name: "Work", provider: "caldav", canCreateLists: true},
                                   {id: "three", name: "Empty connection", provider: "caldav", canCreateLists: true}]
            root.widget.lists = [{id: "inbox", sourceId: "one", name: "Local / Inbox", listName: "Inbox", accountName: "Local", taskOnly: true, readOnly: false, canRename: false, canDelete: false},
                                 {id: "empty", sourceId: "one", name: "Empty read-only list", readOnly: true, canRename: false, canDelete: false},
                                 {id: "work", sourceId: "two", name: "Work tasks", readOnly: false, canRename: true, canDelete: true}]
            root.widget.todos = [{id: "a", sourceId: "one", text: "A task", listId: "inbox", completed: false, parentId: null},
                                 {id: "b", sourceId: "one", text: "A child", listId: "inbox", completed: false, parentId: "a"},
                                 {id: "c", sourceId: "one", text: "A done task", listId: "inbox", completed: true, parentId: null},
                                 {id: "d", sourceId: "two", text: "Another provider", listId: "work", completed: false, parentId: null},
                                 {id: "e", sourceId: "two", text: "Work done", listId: "work", completed: true, parentId: null}]
            if (root.widget.activeCount !== 3 || root.widget.doneCount !== 2 || root.widget.depthOf("b") !== 1)
                console.error("SMOKE FAILURE: global task model")
            const rows = root.widget.displayRows
            if (root.widget.connectionSummary.length !== 3 || root.widget.connectionSummary[0].lists !== 2 || root.widget.connectionSummary[1].lists !== 1)
                console.error("SMOKE FAILURE: overview must show all connections and their list counts")
            const secondSource = root.widget.sourceRowIndex("two")
            if (secondSource <= 0 || rows[secondSource].source.id !== "two" || root.widget.sourceRowIndex("missing") !== -1)
                console.error("SMOKE FAILURE: connection jump targets must match their source headings")
            root.widget.revealSource("two")
            if (root.widget.displayRows.length !== rows.length || root.widget.filter !== "active")
                console.error("SMOKE FAILURE: connection navigation must not filter the grouped view")
            if (rows.filter(r => r.kind === "source").length !== 3 || rows.filter(r => r.kind === "list").length !== 3 || rows.filter(r => r.kind === "task").length !== 3)
                console.error("SMOKE FAILURE: all providers/lists must appear together")
            if (rows.filter(r => r.kind === "empty").length !== 2)
                console.error("SMOKE FAILURE: empty lists/connections must remain visible")
            root.widget.filter = "done"
            if (root.widget.displayRows.filter(r => r.kind === "task").length !== 2 || root.widget.displayRows.filter(r => r.kind === "list").length !== 3)
                console.error("SMOKE FAILURE: global filter must preserve group headings")
            root.widget.filter = "all"
            if (root.widget.displayRows.filter(r => r.kind === "task").length !== 5)
                console.error("SMOKE FAILURE: all-list view must include all tasks")
            if (!root.widget.listWritable("work") || root.widget.listWritable("empty") || root.widget.beginComposer("empty", "", ""))
                console.error("SMOKE FAILURE: per-list write permissions")
            root.widget.beginComposer("work", "", "d")
            if (root.widget.composer.sourceId !== "two" || root.widget.composer.listId !== "work" || root.widget.composer.parentId !== "d")
                console.error("SMOKE FAILURE: subtask must target its own provider/list")
            if (root.widget.beginComposer("work", "a", ""))
                console.error("SMOKE FAILURE: cross-list edit must be rejected")
            root.widget.beginComposer("inbox", "a", "")
            if (root.widget.composer.sourceId !== "one" || root.widget.draftText !== "A task")
                console.error("SMOKE FAILURE: edit composer must preserve title and target")
            root.widget.cancelComposer()
            if (root.widget.startListOperation("create_list", "one", "") || !root.widget.startListOperation("create_list", "two", ""))
                console.error("SMOKE FAILURE: source-local list creation capability")
            root.widget.listOperation = null
            root.widget.filter = "active"
            root.widget.toggleList("inbox")
            if (!root.widget.isListCollapsed("inbox") || root.widget.displayRows.some(row => row.kind === "task" && row.task.listId === "inbox") ||
                !root.widget.displayRows.some(row => row.kind === "list" && row.list.id === "inbox"))
                console.error("SMOKE FAILURE: collapsed list must hide only its contents")
            root.widget.toggleSource("one")
            if (root.widget.displayRows.some(row => row.kind === "list" && row.list.sourceId === "one") || root.widget.sourceRowIndex("one") < 0)
                console.error("SMOKE FAILURE: collapsed connection must retain heading and hide all child lists")
            root.widget.toggleSource("two")
            if (root.widget.displayRows.some(row => row.kind === "task") || root.widget.activeCount !== 3 || root.widget.visibleCount !== 5)
                console.error("SMOKE FAILURE: collapsing groups must not change global counts")
            root.widget.toggleSource("one")
            if (!root.widget.isListCollapsed("inbox"))
                console.error("SMOKE FAILURE: reopening provider must preserve child collapse state")
            const restoredComponent = Qt.createComponent("file://" + Quickshell.env("CALDAV_TASKS_PROJECT") + "/CalDAVTasks.qml")
            root.restoredWidget = restoredComponent.createObject(scene.contentItem, {pluginService: stateService})
            if (!root.restoredWidget || !root.restoredWidget.isSourceCollapsed("two") || !root.restoredWidget.isListCollapsed("inbox"))
                console.error("SMOKE FAILURE: collapse state must survive widget recreation")
            if (root.restoredWidget) root.restoredWidget.visible = false
            root.widget.toggleList("work")
            root.widget.beginComposer("work", "", "d")
            if (root.widget.isSourceCollapsed("two") || root.widget.isListCollapsed("work"))
                console.error("SMOKE FAILURE: explicit add/edit must reveal its composer")
            root.widget.draftText = "Keep this draft"
            root.widget.toggleSource("two")
            root.widget.toggleSource("two")
            if (root.widget.draftText !== "Keep this draft" || !root.widget.composer || !root.widget.displayRows.some(row => row.kind === "composer"))
                console.error("SMOKE FAILURE: draft must survive folding its parent")
            root.widget.toggleList("work")
            root.widget.toggleSource("two")
            root.widget.revealSource("two")
            if (root.widget.isSourceCollapsed("two") || !root.widget.isListCollapsed("work"))
                console.error("SMOKE FAILURE: overview jump must expand provider but preserve child folds")
            root.widget.cancelComposer()
            root.widget.setGroupCollapsed("lists", "work", false)
            root.widget.setGroupCollapsed("lists", "inbox", false)
            root.widget.revealSource("one")
            const originalTasks = root.widget.todos.slice()
            root.widget.todos = originalTasks.concat([
                {id: "f", sourceId: "two", listId: "work", text: "Work extra", completed: false},
                {id: "g", sourceId: "two", listId: "work", text: "Work extra", completed: false},
                {id: "h", sourceId: "two", listId: "work", text: "Work extra", completed: false},
                {id: "i", sourceId: "one", listId: "empty", text: "Other list", completed: false},
                {id: "j", sourceId: "one", listId: "empty", text: "Other list", completed: false},
                {id: "k", sourceId: "one", listId: "empty", text: "Other list", completed: false}
            ])
            // System has 5 open tasks in total, Work has 4. The individual
            // Work list is largest, but must not determine provider priority.
            if (root.widget.sortedSources[0].id !== "one" || root.widget.sortedListsForSource("one")[0].id !== "empty")
                console.error("SMOKE FAILURE: providers must use total open tasks and lists their own counts")
            root.widget.todos = root.widget.todos.filter(task => task.id !== "j" && task.id !== "k")
            if (root.widget.sortedSources[0].id !== "two" || root.widget.connectionSummary[0].id !== "two" || root.widget.displayRows[0].source.id !== "two")
                console.error("SMOKE FAILURE: priority order must update in headings and overview")
            root.widget.toggleList("work")
            root.widget.toggleSource("two")
            root.widget.filter = "done"
            if (root.widget.sortedSources[0].id !== "two" || root.widget.sortedListsForSource("one")[0].id !== "inbox")
                console.error("SMOKE FAILURE: folding/filtering must not affect open-task sorting")
            root.widget.setGroupCollapsed("sources", "two", false)
            root.widget.setGroupCollapsed("lists", "work", false)
            root.widget.todos = originalTasks.map(task => Object.assign({}, task, {completed: true}))
            if (root.widget.sortedSources.map(source => source.id).join(",") !== "three,one,two" || root.widget.sortedListsForSource("one")[0].id !== "empty")
                console.error("SMOKE FAILURE: equal open counts must sort alphabetically")
            root.widget.todos = originalTasks
            root.widget.filter = "active"
            root.settings.sources = [{id: "one", name: "System", enabled: true, provider: "evolution"}]
            root.settings.provider = "evolution"
            root.fixturesTested = true
        }
    }
    Timer {
        interval: 3000
        running: true
        onTriggered: {
            if (!Theme.isLightMode || Theme.matugenAvailable)
                console.error("SMOKE FAILURE: preview must use light mode with matugen disabled")
            if (!root.fixturesTested)
                console.error("SMOKE FAILURE: task fixtures did not finish loading")
            if (root.widget && root.widget.errorMessage)
                console.error("SMOKE FAILURE: " + root.widget.errorMessage)
            else if (root.widget)
                console.warn("SMOKE BACKEND READY: " + !root.widget.busy)
            const imagePath = Quickshell.env("CALDAV_TASKS_SCREENSHOT")
            if (imagePath && root.popout) {
                scene.contentItem.grabToImage(result => { result.saveToFile(imagePath); Qt.quit() })
            } else Qt.quit()
        }
    }
}
