# Policy Checker Gotchas

## The Problem

Policy checkers in Viaduct frequently fail due to:
- Incorrect GlobalID handling (policy executors get raw strings)
- Missing factory registration in `configureSchema()`
- Not handling both field-level and type-level checks
- Unclear error messages making debugging difficult

## Why It Happens

Policy execution happens BEFORE argument deserialization:

```
GraphQL Query
    |
    v
[Policy Executor]  <-- Gets raw base64 strings
    |
    v
[Argument Deserialization]  <-- @idOf converts to GlobalID<T>
    |
    v
[Resolver]  <-- Gets GlobalID<T> objects
```

This architectural constraint means policy executors cannot access the decoded GlobalID - they must handle base64 strings directly.

## The Solution

### 1. Policy Directive Definition

```graphql
"""
Directive to enforce group membership.
"""
directive @requiresGroupMembership(
  groupIdField: String = "groupId"
) on FIELD_DEFINITION | OBJECT
```

- `FIELD_DEFINITION` - Apply to queries/mutations (checked once)
- `OBJECT` - Apply to types (checked per-row)

### 2. Policy Executor with Correct GlobalID Handling

```kotlin
class GroupMembershipExecutor(
    private val groupIdFieldName: String,
    private val groupService: GroupService
) : CheckerExecutor {

    override val requiredSelectionSets: Map<String, RequiredSelectionSet?> = emptyMap()

    override suspend fun execute(
        arguments: Map<String, Any?>,
        objectDataMap: Map<String, EngineObjectData>,
        context: EngineExecutionContext
    ): CheckerResult {
        val requestContext = context.requestContext as? GraphQLRequestContext
            ?: return PolicyError("Authentication required")

        val userId = requestContext.userId
        val objectData = objectDataMap[""]

        // Determine if this is field-level or type-level check
        return if (objectData == null) {
            checkFieldLevel(arguments, userId, context)
        } else {
            checkTypeLevel(objectData, userId, context)
        }
    }

    private suspend fun checkFieldLevel(
        arguments: Map<String, Any?>,
        userId: String,
        context: EngineExecutionContext
    ): CheckerResult {
        val groupIdArg = arguments[groupIdFieldName]
        if (groupIdArg == null) {
            // Try input object
            val inputArg = arguments["input"]
            if (inputArg != null) {
                return checkFromInput(inputArg, userId, context)
            }
            return CheckerResult.Success  // No group to check
        }

        val groupId = extractInternalId(groupIdArg)
        return checkMembership(userId, groupId, context)
    }

    private suspend fun checkTypeLevel(
        objectData: EngineObjectData,
        userId: String,
        context: EngineExecutionContext
    ): CheckerResult {
        val groupId = try {
            objectData.fetch(groupIdFieldName) as? String
        } catch (e: Exception) {
            null
        }

        if (groupId == null) {
            return CheckerResult.Success  // No group = public access
        }

        return checkMembership(userId, groupId, context)
    }

    // CRITICAL: Handle both GlobalID objects and base64 strings
    private fun extractInternalId(arg: Any): String {
        return when (arg) {
            is GlobalID<*> -> arg.internalID
            is String -> {
                try {
                    val decoded = String(Base64.getDecoder().decode(arg))
                    decoded.substringAfter(":")
                } catch (e: Exception) {
                    arg  // Already a plain ID
                }
            }
            else -> error("Unexpected type: ${arg::class.java.name}")
        }
    }

    private suspend fun checkMembership(
        userId: String,
        groupId: String,
        context: EngineExecutionContext
    ): CheckerResult {
        val requestContext = context.requestContext as? GraphQLRequestContext
            ?: return PolicyError("Request context not found")

        val isMember = groupService.isUserMemberOfGroup(userId, groupId)

        return if (isMember) {
            CheckerResult.Success
        } else {
            PolicyError("Access denied: not a member of group $groupId")
        }
    }
}

class PolicyError(message: String) : CheckerResult.Error {
    override val error = RuntimeException(message)
    override fun isErrorForResolver(ctx: CheckerResultContext) = true
    override fun combine(fieldResult: CheckerResult.Error) = fieldResult
}
```

### 3. Policy Factory (MUST Register!)

```kotlin
class GroupMembershipCheckerFactory(
    private val schema: ViaductSchema,
    private val groupService: GroupService
) : CheckerExecutorFactory {

    private val graphQLSchema = schema.schema

    override fun checkerExecutorForField(
        typeName: String,
        fieldName: String
    ): CheckerExecutor? {
        val field = graphQLSchema.getObjectType(typeName)
            ?.getFieldDefinition(fieldName)
            ?: return null

        if (!field.hasAppliedDirective("requiresGroupMembership")) {
            return null
        }

        val directive = field.getAppliedDirective("requiresGroupMembership")
        val groupIdField = directive.getArgument("groupIdField")
            ?.getValue() as? String ?: "groupId"

        return GroupMembershipExecutor(groupIdField, groupService)
    }

    override fun checkerExecutorForType(typeName: String): CheckerExecutor? {
        val type = graphQLSchema.getObjectType(typeName)
            ?: return null

        if (!type.hasAppliedDirective("requiresGroupMembership")) {
            return null
        }

        val directive = type.getAppliedDirective("requiresGroupMembership")
        val groupIdField = directive.getArgument("groupIdField")
            ?.getValue() as? String ?: "groupId"

        return GroupMembershipExecutor(groupIdField, groupService)
    }
}
```

### 4. Register the Factory (CRITICAL!)

```kotlin
class KoinTenantCodeInjector : ViaductTenantCodeInjector, KoinComponent {
    private val groupService: GroupService by inject()

    override fun configureSchema(viaductSchema: ViaductSchema) {
        // MUST register your factory here!
        viaductSchema.registerCheckerExecutorFactory(
            GroupMembershipCheckerFactory(viaductSchema, groupService)
        )
    }
}
```

## Before/After Examples

### GlobalID Handling in Executor

**Before (Wrong):**
```kotlin
private fun extractGroupId(arg: Any): String {
    // Assumes GlobalID object - breaks in production!
    return (arg as GlobalID<*>).internalID
}
```

**After (Correct):**
```kotlin
private fun extractGroupId(arg: Any): String {
    return when (arg) {
        is GlobalID<*> -> arg.internalID
        is String -> {
            try {
                String(Base64.getDecoder().decode(arg)).substringAfter(":")
            } catch (e: Exception) {
                arg
            }
        }
        else -> error("Unexpected: ${arg::class.java}")
    }
}
```

### Missing Factory Registration

**Before (Wrong):**
```kotlin
class TenantCodeInjector : ViaductTenantCodeInjector {
    override fun configureSchema(viaductSchema: ViaductSchema) {
        // Factory created but NOT registered!
        val factory = GroupMembershipCheckerFactory(viaductSchema, groupService)
        // Oops, forgot to register it
    }
}
```

**After (Correct):**
```kotlin
class TenantCodeInjector : ViaductTenantCodeInjector {
    override fun configureSchema(viaductSchema: ViaductSchema) {
        val factory = GroupMembershipCheckerFactory(viaductSchema, groupService)
        viaductSchema.registerCheckerExecutorFactory(factory)  // Don't forget!
    }
}
```

## Detection

### Signs Your Policy Isn't Working

1. **No authorization errors** - Requests succeed when they should fail
2. **NullPointerException** - Casting GlobalID when it's actually String
3. **Base64 decode errors** - Trying to decode already-decoded value
4. **Policy never called** - Factory not registered

### Debugging Checklist

```kotlin
// Add logging to verify execution
override suspend fun execute(...): CheckerResult {
    println("Policy executing for: $arguments")
    println("Object data: $objectDataMap")
    // ...
}
```

## Prevention

### Policy Checklist

- [ ] Directive defined in `.graphqls` file
- [ ] Directive applied to fields/types with `@directiveName`
- [ ] Executor implements `CheckerExecutor` interface
- [ ] Executor handles BOTH `objectData == null` (field-level) and `!= null` (type-level)
- [ ] Executor handles BOTH `GlobalID<*>` and `String` for ID arguments
- [ ] Error result implements `CheckerResult.Error`
- [ ] Factory implements `CheckerExecutorFactory`
- [ ] Factory is registered in `configureSchema()`
- [ ] Build succeeded after changes

### Template for New Policy

```kotlin
// 1. Directive (PolicyDirectives.graphqls)
directive @myPolicy(param: String) on FIELD_DEFINITION | OBJECT

// 2. Executor
class MyPolicyExecutor(private val param: String) : CheckerExecutor {
    override val requiredSelectionSets = emptyMap<String, RequiredSelectionSet?>()

    override suspend fun execute(
        arguments: Map<String, Any?>,
        objectDataMap: Map<String, EngineObjectData>,
        context: EngineExecutionContext
    ): CheckerResult {
        val objectData = objectDataMap[""]
        return if (objectData == null) {
            checkFieldLevel(arguments, context)
        } else {
            checkTypeLevel(objectData, context)
        }
    }
}

// 3. Factory
class MyPolicyFactory(
    private val schema: ViaductSchema
) : CheckerExecutorFactory {
    override fun checkerExecutorForField(typeName: String, fieldName: String): CheckerExecutor? {
        val field = schema.schema.getObjectType(typeName)
            ?.getFieldDefinition(fieldName) ?: return null
        if (!field.hasAppliedDirective("myPolicy")) return null
        val param = field.getAppliedDirective("myPolicy")
            .getArgument("param")?.getValue() as? String ?: "default"
        return MyPolicyExecutor(param)
    }

    override fun checkerExecutorForType(typeName: String): CheckerExecutor? {
        val type = schema.schema.getObjectType(typeName) ?: return null
        if (!type.hasAppliedDirective("myPolicy")) return null
        val param = type.getAppliedDirective("myPolicy")
            .getArgument("param")?.getValue() as? String ?: "default"
        return MyPolicyExecutor(param)
    }
}

// 4. Registration
override fun configureSchema(viaductSchema: ViaductSchema) {
    viaductSchema.registerCheckerExecutorFactory(MyPolicyFactory(viaductSchema))
}
```

## Common Patterns

### Owner-Only Access

```graphql
directive @requiresOwnership(ownerIdField: String = "ownerId") on OBJECT
```

```kotlin
class OwnershipExecutor(private val ownerIdField: String) : CheckerExecutor {
    override suspend fun execute(...): CheckerResult {
        val objectData = objectDataMap[""] ?: return CheckerResult.Success
        val ownerId = objectData.fetch(ownerIdField) as? String
        val currentUserId = (context.requestContext as GraphQLRequestContext).userId

        return if (ownerId == currentUserId) {
            CheckerResult.Success
        } else {
            PolicyError("You don't own this resource")
        }
    }
}
```

### Role-Based Access

```graphql
directive @requiresRole(role: String!) on FIELD_DEFINITION
```

```kotlin
class RoleExecutor(
    private val requiredRole: String,
    private val userService: UserService
) : CheckerExecutor {
    override suspend fun execute(...): CheckerResult {
        val userId = (context.requestContext as GraphQLRequestContext).userId
        val userRoles = userService.getRoles(userId)

        return if (requiredRole in userRoles) {
            CheckerResult.Success
        } else {
            PolicyError("Requires role: $requiredRole")
        }
    }
}
```

## See Also

- [GlobalIDs](global-ids.md) - GlobalID handling patterns
- [Entities](../core/entities.md) - Node and field resolvers
- [Mutations](../core/mutations.md) - Mutation authorization
