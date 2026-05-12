---
name: viaduct-scopes
description: |
  Viaduct scope and visibility pattern. Use when adding admin-only mutations, using @scope directive, or restricting API visibility to admin consumers.
---

# Viaduct Scope Pattern

## Default Scope (Most Common)

Most types only need default scope:

```graphql
type Tag implements Node @resolver @scope(to: ["default"]) {
  id: ID!
  name: String!
  color: String
}
```

## Admin Mutations

Use `extend type Mutation` for admin-only mutations - this works correctly:

```graphql
# ✅ Admin mutations work with @resolver
extend type Mutation @scope(to: ["admin"]) {
  deleteAllTags: Boolean! @resolver
  resetData: Boolean! @resolver
}
```

```kotlin
package com.viaduct.resolvers

import com.viaduct.resolvers.resolverbases.MutationResolvers

@Resolver
class DeleteAllTagsResolver : MutationResolvers.DeleteAllTags() {

    override suspend fun resolve(ctx: Context): Boolean {
        // TODO: Delete all tags
        return true
    }
}
```

## ⚠️ CRITICAL: Object Type Extensions Don't Work

**Do NOT use `extend type` for object types (Tag, User, etc.) when the base type has `@resolver`:**

```graphql
# ❌ DOESN'T WORK - fields get stripped during schema assembly
type Tag implements Node @resolver @scope(to: ["default"]) { ... }
extend type Tag @scope(to: ["admin"]) {
  internalNotes: String  # Gets stripped → empty block → error!
}
```

**The framework strips fields from extend blocks on object types with @resolver.**

## What Works vs What Doesn't

| Scenario | Works? |
|----------|--------|
| `extend type Query @scope(to: ["admin"])` with `@resolver` fields | ✅ Yes |
| `extend type Mutation @scope(to: ["admin"])` with `@resolver` fields | ✅ Yes |
| `extend type Tag @scope(to: ["admin"])` with any fields | ❌ No |

## Recommended Pattern

For admin-only operations, use mutations instead of fields:

```graphql
# ✅ CORRECT - use admin mutations
extend type Mutation @scope(to: ["admin"]) {
  getTagInternalNotes(id: ID! @idOf(type: "Tag")): String @resolver
  setTagInternalNotes(id: ID! @idOf(type: "Tag"), notes: String!): Tag! @resolver
}
```

## ⚠️ CRITICAL: Cross-Type Scope Compatibility

**Every type referenced by another type must share at least one scope with it.** Viaduct validates this at startup and will throw `SchemaScopeValidationError` if not satisfied.

```graphql
# ❌ FAILS AT STARTUP
type AdminStats @scope(to: ["admin"]) {
  topPosts: [BlogPost!]!  # BlogPost is only "default" — no overlap with "admin"
}
type BlogPost implements Node @scope(to: ["default"]) { ... }

# ✅ CORRECT — BlogPost also declares "admin" so the reference is valid
type AdminStats @scope(to: ["admin"]) {
  topPosts: [BlogPost!]!
}
type BlogPost implements Node @scope(to: ["default", "admin"]) { ... }
```

This applies to **all** cross-type references: field types, return types in Query/Mutation extensions, and interface implementations. If a type appears in an admin query or admin type's fields, it must include `"admin"` in its own `@scope`.

## Runtime Behavior: Scope Denial Is a GraphQL Error, Not a 401

When a client calls an operation that doesn't exist in their scope, Viaduct returns **HTTP 200 with a GraphQL `errors` array** (field not found in schema), not an HTTP 401. The schema presented to each scope simply omits fields the scope doesn't have access to.

```kotlin
// ❌ WRONG — Viaduct does not return 401 for out-of-scope operations
resp.status shouldBe HttpStatusCode.Unauthorized

// ✅ CORRECT
val body = resp.bodyAsText()
body shouldContain "errors"
```
