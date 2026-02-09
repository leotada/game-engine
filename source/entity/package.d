module entity;

import math.vector;
import component;
import pool.poolable;

class Entity : IPoolable
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
            return cast(bool)(T.classinfo in componentDict);
        return false;
    }

    /// Reset entity for reuse (IPoolable implementation)
    void reset()
    {
        id = 0;
        active = true;
        position = Vector(0, 0, 0);
        componentDict.clear();
    }

    ~this()
    {
        componentDict.clear();
    }
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

    // Test reset
    entity.id = 42;
    entity.active = false;
    entity.position.x = 100;
    entity.reset();
    assert(entity.id == 0);
    assert(entity.active == true);
    assert(entity.position.x == 0);
    assert(entity.hasComponent!Component() == false);
}
