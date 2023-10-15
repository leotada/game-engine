module entity.entity_manager;

import entity;

@safe:


class EntityManager
{
    immutable int maxSize = 1_000_000;
    private Entity[maxSize] entities;
    private uint index = 0;

    void add(Entity entity)
    {
        if (index > maxSize)
            throw new Exception("Maximum Entities registered reached");
        else if (index == 0)
            index++;

        entity.id = index;
        entities[index] = entity;
        index++;
    }

    void remove(uint value)
    {
        entities[value] = null;
    }

    Entity get(uint value)
    {
        return entities[value];
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
}
