module entity.manager;

import entity;

@safe:


class EntityManager
{
    immutable int maxSize = 1_000_000;
    private Entity[maxSize] entities;
    private uint index = 0;
    private Entity[][TypeInfo] referenceByComponent;

    void add(Entity entity)
    {
        if (index > maxSize)
            throw new Exception("Maximum Entities registered reached");
        entity.id = index;
        this.entities[index] = entity;
        index++;
        updateReferenceByComponent(entity);
    }

    // void remove(uint value)
    // {
    //     entities[value] = null;
    // }

    Entity get(uint value)
    {
        return this.entities[value];
    }

    Entity[] getAll()
    {
        return this.entities;
    }

    void updateReferenceByComponent(ref Entity entity)
    {
        if (entity is null)
            return;

        TypeInfo[] types = entity.getComponentTypes();
        foreach (TypeInfo key; types)
        {
            if (cast(bool) (key in referenceByComponent))
            {
                referenceByComponent[key] ~= entity;
            }
            else
            {
                referenceByComponent[key] = [entity];
            }
        }
    }

    Entity[] getByComponent(T)()
    {
        if (cast(bool) (T.classinfo in referenceByComponent))
            return referenceByComponent[T.classinfo];
        else
        {
            return [];
        }
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
