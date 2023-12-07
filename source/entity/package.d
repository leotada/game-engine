module entity;

import math.vector;
import component;


class Entity
{
    uint id;
    bool active = true;
    Vector position;
    public Component[TypeInfo] componentDict;
    
    void addComponent(T)(T component)
    {
        componentDict[T.classinfo] = component;
    }

    T getComponent(T)()
    {
        TypeInfo componentType = T.classinfo;
        if (hasComponent!T())
            return cast(T) componentDict[componentType];
        return null;
    }

    TypeInfo[] getComponentTypes()
    {
        return componentDict.keys;
    }

    bool hasComponent(T)()
    {
        if (componentDict.length > 0)
            return cast(bool) (T.classinfo in componentDict);
        return false;
    }

    // ~this()
    // {
    //     componentDict.clear();
    // }
}

unittest
{
    auto entity = new Entity();
    auto component = new Component();
    assert(entity.hasComponent!Component() == false);
    Component component2;
    assert(component2 is null);

    entity.addComponent!Component(component);
    assert(entity.hasComponent!Component() == true);
    component2 = entity.getComponent!Component();
    assert(component2 !is null);
}
