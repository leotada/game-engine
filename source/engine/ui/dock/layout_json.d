/// JSON serialization and persistence for dock layouts.
module engine.ui.dock.layout_json;

import std.json;
import engine.ui.dock.dock_space;

@safe:

/// Serialize dock space layout into a JSON string.
string serializeDockLayout(in DockSpace dock) {
    if (dock.root == 0) return "{}";

    float rootW = dock.node(dock.root).width;
    float rootH = dock.node(dock.root).height;
    JSONValue rootObj = JSONValue([
        "version": JSONValue(1),
        "root": JSONValue(dock.root),
        "width": JSONValue(rootW > 0 ? rootW : 1024.0f),
        "height": JSONValue(rootH > 0 ? rootH : 768.0f)
    ]);
    JSONValue[] nodesArray;

    foreach (uint i; 1 .. dock.MAX_NODES) {
        if (dock.pool[i].inUse) {
            const n = &dock.pool[i];
            JSONValue nodeObj;
            nodeObj["index"] = JSONValue(i);
            nodeObj["id"] = JSONValue(n.id);
            nodeObj["ratio"] = JSONValue(n.splitRatio);
            nodeObj["childA"] = JSONValue(n.childA);
            nodeObj["childB"] = JSONValue(n.childB);

            final switch (n.kind) {
                case DockKind.leaf:
                    nodeObj["kind"] = JSONValue("leaf");
                    JSONValue[] tabsArr;
                    foreach (t; 0 .. n.tabCount) {
                        tabsArr ~= JSONValue(n.getTab(t).idup);
                    }
                    nodeObj["tabs"] = JSONValue(tabsArr);
                    nodeObj["active"] = JSONValue(n.activeTab);
                    break;
                case DockKind.splitHorizontal:
                    nodeObj["kind"] = JSONValue("splitH");
                    break;
                case DockKind.splitVertical:
                    nodeObj["kind"] = JSONValue("splitV");
                    break;
            }

            nodesArray ~= nodeObj;
        }
    }

    rootObj["nodes"] = JSONValue(nodesArray);
    return rootObj.toString();
}

/// Deserialize dock space layout from JSON.
bool deserializeDockLayout(ref DockSpace dock, string jsonStr) {
    if (jsonStr.length == 0) return false;

    try {
        JSONValue rootObj = parseJSON(jsonStr);
        if (rootObj.type != JSONType.object) return false;

        // Clear existing nodes
        foreach (uint i; 1 .. dock.MAX_NODES) {
            dock.pool[i].inUse = false;
        }

        auto nodesVal = () @trusted { return "nodes" in rootObj.object; }();
        if (nodesVal is null || nodesVal.type != JSONType.array) return false;

        auto arraySlice = () @trusted { return nodesVal.array; }();
        foreach (ref item; arraySlice) {
            if (item.type != JSONType.object) continue;
            auto obj = () @trusted { return item.object; }();

            uint idx = cast(uint)obj["index"].integer;
            if (idx == 0 || idx >= dock.MAX_NODES) continue;

            auto n = &dock.pool[idx];
            n.inUse = true;
            n.id = cast(uint)obj["id"].integer;
            n.splitRatio = cast(float)obj["ratio"].floating;
            n.childA = cast(uint)obj["childA"].integer;
            n.childB = cast(uint)obj["childB"].integer;

            string kindStr = obj["kind"].str;
            if (kindStr == "splitH") {
                n.kind = DockKind.splitHorizontal;
            } else if (kindStr == "splitV") {
                n.kind = DockKind.splitVertical;
            } else {
                n.kind = DockKind.leaf;
                n.tabCount = 0;
                n.activeTab = cast(uint)obj["active"].integer;

                auto tabsVal = () @trusted { return "tabs" in obj; }();
                if (tabsVal !is null && tabsVal.type == JSONType.array) {
                    auto tabsArr = () @trusted { return tabsVal.array; }();
                    foreach (ref t; tabsArr) {
                        n.addTab(t.str);
                    }
                }
            }
        }

        float w = 1024.0f, h = 768.0f;
        auto wVal = () @trusted { return "width" in rootObj.object; }();
        auto hVal = () @trusted { return "height" in rootObj.object; }();
        if (wVal !is null) w = cast(float)wVal.floating;
        if (hVal !is null) h = cast(float)hVal.floating;

        auto rootVal = () @trusted { return "root" in rootObj.object; }();
        if (rootVal !is null) {
            dock.setRoot(cast(uint)rootVal.integer);
            dock.computeLayout(0, 0, w, h);
        }
        return true;
    } catch (Exception) {
        return false;
    }
}

unittest {
    DockSpace original;
    original.initDefaultLayout(1024, 768);

    string json = serializeDockLayout(original);
    assert(json.length > 50);

    DockSpace restored;
    assert(deserializeDockLayout(restored, json));
    assert(restored.root == original.root);
    assert(restored.node(restored.root).kind == original.node(original.root).kind);

    uint origCenter = original.findLeafAt(500, 200);
    uint restCenter = restored.findLeafAt(500, 200);
    assert(restCenter != 0);
    assert(restored.node(restCenter).getTab(0) == original.node(origCenter).getTab(0));
}
