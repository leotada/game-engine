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
        entity.id = index;
        this.entities[index] = entity;
        index++;
    }

    void remove(uint value)
    {
        entities[value] = null;
    }

    Entity get(uint value)
    {
        return this.entities[value];
    }

    Entity[] getByComponent(T)()
    {
        Entity[] entitiesToReturn = [];
        foreach (ref Entity entity; this.entities)
        {
            if (entity !is null)
            {
                if (entity.hasComponent!T())
                    entitiesToReturn ~= entity;
            }
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
