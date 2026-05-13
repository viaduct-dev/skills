---
name: viaduct-batch
description: |
  Viaduct batch resolution pattern. Use when preventing N+1 queries, implementing batchResolve, using FieldValue, or resolving lists of related entities efficiently.
---

# Viaduct Batch Resolution Pattern

Declare `@resolver(isBatching: true)` in the schema and implement `batchResolve` to prevent N+1 queries:

```kotlin
package com.viaduct.resolvers

import com.viaduct.resolvers.resolverbases.GroupResolvers
import viaduct.api.FieldValue
import viaduct.api.resolver.Resolver
import viaduct.api.grts.Tag

@Resolver("fragment _ on Group { id }")
class GroupTagsResolver : GroupResolvers.Tags() {

    override suspend fun batchResolve(contexts: List<Context>): List<FieldValue<List<Tag>>> {
        // 1. Collect all parent IDs
        val groupIds = contexts.map { it.getObjectValue().getId().internalID }

        // 2. Fetch all data in ONE query
        // TODO: val tagsByGroup = fetchTagsForGroups(groupIds)

        // 3. Return results in SAME ORDER as contexts
        return contexts.map { ctx ->
            val groupId = ctx.getObjectValue().getId().internalID
            // Return empty list as placeholder
            FieldValue.ofValue(emptyList<Tag>())
        }
    }
}
```

## FieldValue Return Types

| Method | Use Case |
|--------|----------|
| `FieldValue.ofValue(obj)` | Successful resolution |
| `FieldValue.ofError(exception)` | Per-item error |
| `FieldValue.ofNull()` | Explicit null |

## Critical Rules

1. **Return list in SAME ORDER as input contexts**
2. **Return `List<FieldValue<T>>` not `List<T>`**
3. **One database query for all items** - that's the whole point

## Schema

```graphql
type Group {
  id: ID!
  tags: [Tag!]! @resolver(isBatching: true)  # Generates batchResolve
}
```

`@resolver(isBatching: true)` generates `batchResolve(...)` instead of `resolve(...)`. A plain `@resolver` generates only `resolve(...)`.

## When to Use Batch

Use `@resolver(isBatching: true)` when:
- Field returns related entities (tags, members, comments)
- Parent type appears in lists
- You see N+1 query patterns in logs

Use regular `@resolver` when:
- Field is a simple computation
- No database access needed
- Parent is always fetched individually

If the field returns a connection type or accepts `first`, `after`, `last`, or `before`, read `connections.md` first. Connection fields may still need batching, but the resolver must return a `*Connection`, not a plain list.
