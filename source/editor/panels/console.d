/// Console panel displaying engine log entries with filters and clear controls.
module editor.panels.console;

import engine.core.log : copyLogHistory, clearLogHistory, LogEntry, LogLevel;
import engine.graphics.types : Color4;
import engine.ui;

@safe:

struct ConsolePanel {
    bool showInfo = true;
    bool showWarn = true;
    bool showError = true;
    uint selectedIndex = uint.max;

    // Buffer to retrieve logs
    private LogEntry[256] logEntries;
    private size_t logCount = 0;

    void updateLogs() nothrow @nogc {
        logCount = copyLogHistory(logEntries);
    }

    /// Build the Console panel UI under parent node.
    void buildUi(ref UiTree tree, UiNodeId parent, in UiTheme theme) nothrow {
        updateLogs();

        // Panel container
        UiStyle panelStyle;
        panelStyle.direction = UiFlexDirection.column;
        panelStyle.widthMode = UiSizeMode.fill;
        panelStyle.heightMode = UiSizeMode.fill;
        panelStyle.backgroundColor = theme.colors.bgBase;

        UiNodeId panel = tree.createNode(parent, panelStyle);

        // Toolbar
        UiStyle tbStyle;
        tbStyle.direction = UiFlexDirection.row;
        tbStyle.alignItems = UiAlign.center;
        tbStyle.justifyContent = UiJustify.spaceBetween;
        tbStyle.height = 28.0f;
        tbStyle.heightMode = UiSizeMode.fixed;
        tbStyle.widthMode = UiSizeMode.fill;
        tbStyle.padding = [2.0f, 8.0f, 2.0f, 8.0f];
        tbStyle.backgroundColor = theme.colors.bgSurface;
        tbStyle.borderWidth = 1.0f;
        tbStyle.borderColor = theme.colors.border;

        UiNodeId tb = tree.createNode(panel, tbStyle);

        // Left controls: Clear button
        UiNodeId clearBtn = button(tree, tb, "Limpar", theme);
        tree.get(clearBtn).customTag = 0xC000_0030;

        // Right controls: Filter indicators
        UiStyle filtersStyle;
        filtersStyle.direction = UiFlexDirection.row;
        filtersStyle.gap = 8.0f;
        UiNodeId filtersRow = tree.createNode(tb, filtersStyle);

        uint infoCount = 0, warnCount = 0, errCount = 0;
        foreach (i; 0 .. logCount) {
            if (logEntries[i].level == LogLevel.info) infoCount++;
            else if (logEntries[i].level == LogLevel.warn) warnCount++;
            else errCount++;
        }

        char[32] infoStr, warnStr, errStr;
        import core.stdc.stdio : snprintf;
        import core.stdc.string : strlen;

        () @trusted {
            snprintf(infoStr.ptr, infoStr.length, "Info: %u", infoCount);
            snprintf(warnStr.ptr, warnStr.length, "Avisos: %u", warnCount);
            snprintf(errStr.ptr, errStr.length, "Erros: %u", errCount);
        }();

        label(tree, filtersRow, infoStr[0 .. () @trusted { return strlen(infoStr.ptr); }()], theme.colors.textDim, 12.0f);
        label(tree, filtersRow, warnStr[0 .. () @trusted { return strlen(warnStr.ptr); }()], theme.colors.warning, 12.0f);
        label(tree, filtersRow, errStr[0 .. () @trusted { return strlen(errStr.ptr); }()], theme.colors.error, 12.0f);

        // Scrollable logs list
        UiNodeId listContainer = scrollView(tree, panel, theme);

        foreach (i; 0 .. logCount) {
            const entry = &logEntries[i];
            Color4 entryColor = theme.colors.text;
            const(char)[] prefix = "[INFO] ";

            if (entry.level == LogLevel.warn) {
                entryColor = theme.colors.warning;
                prefix = "[WARN] ";
            } else if (entry.level == LogLevel.err || entry.level == LogLevel.fatal) {
                entryColor = theme.colors.error;
                prefix = "[ERRO] ";
            }

            UiStyle rowStyle;
            rowStyle.direction = UiFlexDirection.row;
            rowStyle.alignItems = UiAlign.center;
            rowStyle.height = 22.0f;
            rowStyle.heightMode = UiSizeMode.fixed;
            rowStyle.widthMode = UiSizeMode.fill;
            rowStyle.padding = [2.0f, 8.0f, 2.0f, 8.0f];
            rowStyle.backgroundColor = (i % 2 == 1) ? theme.colors.bgSurface : Color4(0, 0, 0, 0);

            UiNodeId row = tree.createNode(listContainer, rowStyle);

            char[128] fullMsg;
            size_t n = 0;
            foreach (c; prefix) if (n < fullMsg.length) fullMsg[n++] = c;
            foreach (c; entry.text()) if (n < fullMsg.length) fullMsg[n++] = c;

            label(tree, row, fullMsg[0 .. n], entryColor, 12.0f);
        }
    }
}
