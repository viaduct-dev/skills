
# Viaduct Query Resolver Pattern

Add query fields using `extend type Query`:

```graphql
extend type Query @scope(to: ["default"]) {
  user(id: ID! @idOf(type: "User")): User @resolver
  users: [User!]! @resolver
}
```

## @idOf Directive

**Always use `@idOf` on ID arguments** - it deserializes GlobalID automatically:

```graphql
# ✅ CORRECT - @idOf enables .internalID
user(id: ID! @idOf(type: "User")): User @resolver

# ❌ WRONG - without @idOf, id is just a String
user(id: ID!): User @resolver
```

## Resolver Implementation

```kotlin
package com.viaduct.resolvers

import com.viaduct.resolvers.resolverbases.QueryResolvers

@Resolver
class UserQueryResolver : QueryResolvers.User() {

    override suspend fun resolve(ctx: Context): User? {
        val userId = ctx.arguments.id.internalID  // @idOf makes this GlobalID<User>

        // TODO: Fetch user from database
        // val data = fetchUser(userId) ?: return null

        return User.Builder(ctx)
            .id(ctx.globalIDFor(User.Reflection, userId))
            .email("placeholder@example.com")
            .build()
    }
}
```

## Key Patterns

| Pattern | Purpose |
|---------|---------|
| `ctx.arguments.id.internalID` | Extract UUID from GlobalID argument |
| `ctx.globalIDFor(Type.Reflection, id)` | Create GlobalID for response |
| `QueryResolvers.FieldName()` | Base class to extend |

## List Query Example

```kotlin
@Resolver
class UsersQueryResolver : QueryResolvers.Users() {

    override suspend fun resolve(ctx: Context): List<User> {
        // TODO: Fetch all users
        // val users = fetchUsers()

        return emptyList()
    }
}
```
