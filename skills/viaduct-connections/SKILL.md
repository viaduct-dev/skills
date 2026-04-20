---
name: viaduct-connections
description: |
  Viaduct-specific connection rules. Use when a field returns a Connection type or accepts first/after/last/before pagination arguments.
---

# Viaduct Connections

Use this only for the Viaduct-specific parts models often get wrong.

## Eval Template Placement

- Edit `src/main/viaduct/schema/Schema.graphqls`.
- Put resolvers in `src/main/kotlin/com/example/resolvers/`.
- Query resolvers extend `com.example.resolvers.resolverbases.QueryResolvers`.

## Minimal Schema Shape

```graphql
type User implements Node @resolver @scope(to: ["default"]) {
  id: ID!
  email: String!
}

type UserConnection @connection {
  edges: [UserEdge!]!
  pageInfo: PageInfo!
  totalCount: Int
}

type UserEdge @edge {
  node: User!
  cursor: String!
}

extend type Query {
  usersConnection(first: Int, after: String): UserConnection! @resolver
}
```

## Critical Rules

- Return `UserConnection`, not `List<User>`.
- `PageInfo` is built in. Do not redefine it.
- Put `totalCount` on the connection type, not on `PageInfo`.
- Use `UserConnection.Builder(ctx)` and `User.Builder(ctx)`.
- If `@connection`, `@edge`, or `PageInfo` seem missing, the Viaduct version is too old. Do not declare them yourself.

## Offset/Limit Backends

For offset/limit storage, use Viaduct helpers instead of hand-rolled cursor logic:

```kotlin
@OptIn(ExperimentalApi::class)
@Resolver
class UsersConnectionResolver : QueryResolvers.UsersConnection() {
    private data class UserRow(val id: String, val email: String)

    override suspend fun resolve(ctx: Context): UserConnection {
        val allUsers = listOf(
            UserRow("1", "alice@example.com"),
            UserRow("2", "bob@example.com"),
            UserRow("3", "charlie@example.com"),
        )
        val (offset, limit) = ctx.arguments.toOffsetLimit()
        val usersPlusOne = allUsers.drop(offset).take(limit + 1)

        return UserConnection.Builder(ctx)
            .fromSlice(usersPlusOne, hasNextPage = usersPlusOne.size > limit) { user ->
                User.Builder(ctx)
                    .id(ctx.globalIDFor(User.Reflection, user.id))
                    .email(user.email)
                    .build()
            }
            .build()
    }
}
```

- Use `fromSlice()` for offset/limit backends.
- Use `fromList()` only when the full list is already loaded.
- Do not manually decode Base64 cursors.

## Opt-In

Connection helpers currently need:

```kotlin
import viaduct.apiannotations.ExperimentalApi
```

and:

```kotlin
@OptIn(ExperimentalApi::class)
```
