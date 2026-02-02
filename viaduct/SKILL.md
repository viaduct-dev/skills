---
name: viaduct
description: Viaduct GraphQL framework development guide for building type-safe Kotlin APIs. Use when working with .graphqls schema files, implementing NodeResolvers, FieldResolvers, QueryResolvers, or MutationResolvers, using @resolver/@scope/@idOf directives, handling GlobalID patterns with .internalID, or troubleshooting Viaduct build errors.
---

# Viaduct Application Development Guide

You are an expert Viaduct developer. Use this documentation to build GraphQL APIs with the Viaduct framework. Follow these patterns exactly to avoid common pitfalls.

## Quick Reference

| Task | Documentation | Key Pattern |
|------|---------------|-------------|
| Define a new entity type | [Entities](resources/core/entities.md) | Implement `Node`, create Node Resolver |
| Add a query field | [Queries](resources/core/queries.md) | Use `@resolver` directive, implement Field Resolver |
| Add a mutation | [Mutations](resources/core/mutations.md) | Extend `Mutation` type, use `@resolver` |
| Handle GlobalIDs | [GlobalID Guide](resources/gotchas/global-ids.md) | Use `@idOf` on inputs, `.internalID` in resolvers |
| Entity relationships | [Relationships](resources/core/relationships.md) | Node references, subqueries |
| Optimize N+1 queries | [Queries](resources/core/queries.md) | Use `batchResolve` |

## Viaduct Architecture

Viaduct is a GraphQL framework that generates type-safe Kotlin code from GraphQL schemas:

```
GraphQL Schema (.graphqls)
        |
   [Viaduct Codegen]
        |
        v
Generated Base Classes (Kotlin)
        |
   [Your Implementation]
        |
        v
Working GraphQL API
```

### Core Concepts

1. **Node Types**: Types implementing `Node` interface are resolvable by GlobalID
2. **Resolvers**: Two types - Node Resolvers (fetch by ID) and Field Resolvers (compute fields)
3. **Responsibility Sets**: Each resolver is responsible for specific fields
4. **GlobalIDs**: Type-safe identifiers encoding type name + internal ID

## Schema-First Development

Always start with the GraphQL schema:

```graphql
# 1. Define your type implementing Node
type User implements Node @scope(to: ["default"]) {
  id: ID!
  firstName: String
  lastName: String
  displayName: String @resolver
}

# 2. Add queries
extend type Query @scope(to: ["default"]) {
  user(id: ID! @idOf(type: "User")): User @resolver
  users: [User!]! @resolver
}

# 3. Add mutations
extend type Mutation @scope(to: ["default"]) {
  createUser(input: CreateUserInput!): User! @resolver
}

# 4. Define inputs with @idOf for ID fields
input CreateUserInput @scope(to: ["default"]) {
  firstName: String!
  lastName: String!
}
```

## Resolver Implementation Pattern

### Node Resolver (for types implementing Node)

```kotlin
@Resolver
class UserNodeResolver @Inject constructor(
    private val userService: UserServiceClient
) : NodeResolvers.User() {

    override suspend fun resolve(ctx: Context): User {
        // ctx.id is GlobalID<User>, use .internalID for database
        val data = userService.fetch(ctx.id.internalID)

        return User.Builder(ctx)
            .firstName(data.firstName)
            .lastName(data.lastName)
            .build()
        // Note: Don't set fields with @resolver (like displayName)
    }
}
```

### Field Resolver (for computed fields)

```kotlin
@Resolver("fragment _ on User { firstName lastName }")
class UserDisplayNameResolver : UserResolvers.DisplayName() {

    override suspend fun resolve(ctx: Context): String? {
        val fn = ctx.objectValue.getFirstName()
        val ln = ctx.objectValue.getLastName()
        return listOfNotNull(fn, ln).joinToString(" ").ifEmpty { null }
    }
}
```

### Query Resolver

```kotlin
@Resolver
class UsersQueryResolver @Inject constructor(
    private val userService: UserServiceClient
) : QueryResolvers.Users() {

    override suspend fun resolve(ctx: Context): List<User> {
        val users = userService.fetchAll()

        return users.map { data ->
            User.Builder(ctx)
                .id(ctx.globalIDFor(User.Reflection, data.id))
                .firstName(data.firstName)
                .lastName(data.lastName)
                .build()
        }
    }
}
```

## Critical: GlobalID Handling

**ALWAYS use `@idOf` directive on ID fields in inputs and arguments:**

```graphql
# CORRECT - generates GlobalID<User>
input UpdateUserInput {
  id: ID! @idOf(type: "User")
  firstName: String
}

# WRONG - generates String, requires manual Base64 decoding
input UpdateUserInput {
  id: ID!  # Missing @idOf!
}
```

**In resolvers, access the internal ID:**

```kotlin
// CORRECT
val userId = input.id.internalID  // String UUID

// WRONG - never do this in resolvers
val decoded = Base64.decode(input.id)  // Don't manually decode!
```

See [GlobalID Guide](resources/gotchas/global-ids.md) for complete patterns.

## Navigation

### Planning & Design
- [Schema Design Patterns](resources/planning/schema-design.md) - How to design your GraphQL schema
- [Task Breakdown](resources/planning/breakdown.md) - Decomposing Viaduct applications

### Core Implementation
- [Entities](resources/core/entities.md) - Node types, node resolvers, field resolvers
- [Queries](resources/core/queries.md) - Query fields, batch resolution
- [Mutations](resources/core/mutations.md) - Mutation implementation
- [Relationships](resources/core/relationships.md) - Entity relationships, subqueries

### Known Gotchas
- [GlobalID Handling](resources/gotchas/global-ids.md) - Common GlobalID mistakes and fixes

### Reference
- [Troubleshooting](resources/reference/troubleshooting.md) - Common errors and solutions

## Development Workflow

1. **Define Schema** - Create `.graphqls` files with types, queries, mutations
2. **Generate Code** - Run `./gradlew generateViaduct...` to create base classes
3. **Implement Resolvers** - Subclass generated base classes
4. **Test** - Write integration tests for your resolvers

## Scopes

Use `@scope` to control API visibility:

```graphql
# Available to all authenticated users
type User @scope(to: ["default"]) { ... }

# Available only to admin API
extend type User @scope(to: ["admin"]) {
  internalNotes: String
}

# Public (no auth required)
type PublicInfo @scope(to: ["public"]) { ... }
```

## Best Practices

1. **Always use `@idOf`** on ID fields in inputs and query arguments
2. **Implement `batchResolve`** when fetching from external services
3. **Don't set `@resolver` fields** in node resolvers (they have their own resolvers)
4. **Use `ctx.globalIDFor()`** when building response objects
