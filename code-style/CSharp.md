# C# Style Guide (derived from Rider/ReSharper settings)

This spec tells an LLM exactly how to format and shape C# code. Terms: MUST/SHOULD/MAY follow RFC meaning.

## Global
- Language: C# (use the most modern syntax available).
- Max line length: 140 characters. Hard wrap rules below respect this limit.

## Expression-bodied members
- Methods and operators: prefer expression-bodied form. Keep on a single line when possible. If multiple statements or the line would exceed 140, use a block body.
- Local functions: prefer expression-bodied; same single-line rule as methods.
- Constructors and destructors: prefer expression-bodied; fall back to blocks if needed.
- When a member is expression-bodied, it MUST be on a single line.

## Object creation
- Use target-typed `new` when the type is apparent from context.

## Qualification rules
- Instance members (fields, properties, events, methods): always qualify with `this.`.
- Static members of the current type: qualify with the containing type name (e.g., `TypeName.Member`).

## Modifiers order (exact sequence)
`private, public, protected, internal, file, new, static, abstract, virtual, async, readonly, override, extern, unsafe, volatile, sealed, required`

The generator MUST output modifiers in that exact order when present.

## Blocks and simple statements
- Empty blocks: write `{}` on the same line as the declaration (no newline inside).
- Simple embedded statements (e.g., after `if`, `for`, `foreach`, `using`): never keep on the same line as the keyword. Start the statement on the next line. Braces may be omitted if the project convention allows, but the statement MUST still start on a new line.
- In `do { ... } while (...)`, place `while` on a new line.

## Properties and accessors
- Expression-bodied properties and accessors: single line.
- Non–expression-bodied (“simple”) accessors: use multi-line blocks; do not compress to one line.

## Line breaking and wrapping
- Break positions for parameter/argument lists:
  - If a declaration or invocation list wraps, the first break goes immediately after the opening parenthesis `(`.
- Chop-if-long strategy:
  - Arguments, parameters, array initializers, list patterns, chained binary expressions, and chained binary patterns stay on one line if they fit; otherwise break them into one-per-line groups consistent with readability.
- Binary expressions: when wrapping, place the operator at the beginning of the new line.
- Single-argument calls SHOULD remain on one line; do not introduce a wrap solely because it is a single argument.

## Enums
- No enforced limit on the number of enum members per line. Use the line-length rule and readability.

## LINQ
- Do not put the `into` keyword on a new line; keep it on the same line as the preceding clause.

## Attributes
- Field attributes: keep on the same line as the field if the field fits on one line; otherwise place the attribute on its own line above.

## Blank lines
- Insert exactly one blank line before control-transfer statements (`return`, `throw`, `break`, `continue`, `yield break`).
- Insert exactly one blank line before any single-line comment.

## Reformatting policy
- Do not preserve existing ad-hoc layout for embedded constructs, list patterns, property patterns, or switch expressions. Normalize formatting according to this spec.

## Built-in types
- Use built-in keywords for native integer types (e.g., `nint`, `nuint`) instead of framework type names.

## Code cleanup and generation hints
- Default cleanup profile: “Reformat Code.”
- Generated implementations: prefer async implementations when applicable; generated code should be non-mutable by default.
- Generated overrides: do not make overrides async by default; generated code should be non-mutable by default.