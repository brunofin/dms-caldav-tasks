import QtQuick
import Quickshell.Io

// Requests (including secrets) travel on stdin, never in process arguments.
Item {
    id: root
    visible: false
    property bool busy: false
    property string output: ""
    property var request: ({})
    signal finished(var data)
    signal failed(string message)

    function run(data) {
        if (busy)
            return false
        request = data
        output = ""
        busy = true
        process.running = true
        return true
    }

    Process {
        id: process
        command: ["python3", Qt.resolvedUrl("backend.py").toString().replace(/^file:\/\//, "")]
        stdinEnabled: true
        onStarted: {
            write(JSON.stringify(root.request) + "\n")
            root.request = ({})
        }
        stdout: StdioCollector {
            onStreamFinished: root.output = text
        }
        // Suppress library diagnostics: DAV errors can include credentials.
        stderr: StdioCollector {}
        onExited: (code, status) => {
            root.busy = false
            try {
                const result = JSON.parse(root.output)
                if (result.success)
                    root.finished(result.data)
                else
                    root.failed(result.message || "CalDAV request failed")
            } catch (_) {
                root.failed("Backend unavailable. Check Python and caldav dependencies.")
            }
        }
    }
}
