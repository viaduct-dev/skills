---
name: viaduct-node-type
description: |
  Viaduct Node type pattern. Use when creating types that implement Node interface, creating NodeResolver classes, or seeing "Unresolved reference NodeResolvers" errors.
---

# Viaduct Node Type Pattern

**⚠️ CRITICAL:** Types implementing Node MUST have `@resolver` directive to generate `NodeResolvers.TypeName`:

```graphql
type User implements Node @resolver @scope(to: ["default"]) {
  id: ID!                      # Required for Node
  email: String
  displayName: String @resolver
}
```

**Without `@resolver` on the type, `NodeResolvers.User` won't exist and your resolver won't compile.**

## NodeResolver Implementation

```kotlin
package com.viaduct.resolvers

import com.viaduct.resolvers.NodeResolvers  // Note: NodeResolvers is NOT in resolverbases!

@Resolver
class UserNodeResolver : NodeResolvers.User() {

    override suspend fun resolve(ctx: Context): User {
        val userId = ctx.id.internalID  // GlobalID -> UUID string

        // TODO: Fetch user from database
        // val data = fetchUser(userId)

        return User.Builder(ctx)
            .email("placeholder@example.com")
            .build()
        // Don't set @resolver fields here - they have their own resolvers
    }
}
```

## Common Error

```
Unresolved reference 'NodeResolvers'
```

**Fix:** Add `@resolver` to the type declaration:
```graphql
# ❌ WRONG - missing @resolver
type Tag implements Node @scope(to: ["default"]) { ... }

# ✅ CORRECT
type Tag implements Node @resolver @scope(to: ["default"]) { ... }
```

## ⚠️ Import Paths (Important!)

**NodeResolvers is in a DIFFERENT package than other resolvers:**

```kotlin
// ✅ CORRECT - NodeResolvers has NO resolverbases subpackage
import com.viaduct.resolvers.NodeResolvers

// ✅ CORRECT - Other resolvers ARE in resolverbases
import com.viaduct.resolvers.resolverbases.QueryResolvers
import com.viaduct.resolvers.resolverbases.MutationResolvers
import com.viaduct.resolvers.resolverbases.TypeResolvers
```

## Checklist

1. Type has `implements Node`
2. Type has `@resolver` directive
3. Type has `@scope(to: ["default"])`
4. Type has `id: ID!` field
5. Resolver extends `NodeResolvers.TypeName()`
6. Import from `resolverbases` subpackage
