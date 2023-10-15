module component.manager;

import component;


class ComponentManager
{
    private Component[][string] componentArray;

    void Add(T)(T component)
    {
        string className = T.mangleof;
        componentArray[className] ~= component;
    }

    T[] Get(T)()
    {
        string className = T.mangleof;
        if (className in componentArray)
            return cast(T[]) componentArray[className];
        else
            return [];
    }

    T Get(T)(uint id) @safe
    {
        string className = T.mangleof;
        if (className in componentArray)
            return componentArray[className][id];
        else
            return null;
    }
}