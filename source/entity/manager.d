module entity.manager;

import entity;

@safe:


class EntityManager
{
    immutable int maxSize = 1_000_000;
    public Entity[maxSize] entities;
    private uint index = 0;

    void add(Entity entity)
    {
        if (index > maxSize)
            throw new Exception("Maximum Entities registered reached");
        index++;
        entity.id = index;
        entities[index] = entity;
    }

    void remove(uint value)
    {
        entities[value] = null;
    }

    Entity get(uint value)
    {
        return entities[value];
    }

    Entity[] getByComponent(T)()
    {
        Entity[] entitiesToReturn = [];
        foreach (ref entity; entities)
        {
            if (entity.hasComponent!T())
                entitiesToReturn ~= entity;
        }

        return entitiesToReturn;
    }
}

unittest
{
    import entity;
    auto em = new EntityManager();
    auto e = new Entity();
    assert(em.index == 0);
    assert(e.id == 0);
    em.add(e);
    assert(em.index == 1);
    assert(e.id == 1);
    import component.particle;
    
    em.getByComponent!Particle();
}
