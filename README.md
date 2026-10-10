# Laur

*Pronounced "lore."*

**An AI-friendly UI language for iOS that compiles to SwiftUI, with A/B testing and analytics built into the language.**

```laur
component ProductCard(product: Product) {
  intent "Show one product with its photo, name and price"

  view {
    stack(.vertical, spacing: .md) {
      image(product.photo, aspect: .square, corner: .md)
      text(product.name, style: .headline)
      text(product.price, style: .body, color: .secondary)
    }
  }

  preview "default"   { product: .sample }
  preview "long name" { product: .sample(name: "An unusually long product name that wraps") }
}
```

> **Status: milestone 4, pre-alpha.** Laur parses and live-previews interactive
> components with loading data, state, actions, lists, conditions and position context.
> Gates, events, navigation and the Swift compiler are designed but not built yet. The
> syntax will change.

## Try it

You need a Mac with Xcode 16 or later.

```sh
git clone https://github.com/laur-lang-forever/laur.git
cd laur
swift run laur preview Examples/ProductCard/ProductCard.laur
```

A preview window opens with each component's previews in the sidebar. Edit
`ProductCard.laur` in any editor and save: the preview updates within a quarter of a
second. Mistakes show up as readable errors above the preview, which keeps showing the
last version that worked.

Try the second example too, and turn on **Show context** in the sidebar to see what
each component knows about its position:

```sh
swift run laur preview Examples/ProductList/ProductList.laur
```

Previews are interactive. Type into the fields and press the buttons in the sign-up form;
**Reset state** under the preview starts it over:

```sh
swift run laur preview Examples/SignUp/SignUp.laur
swift run laur preview Examples/OrderHistory/OrderHistory.laur
```

For a fuller picture of what components can look like, open the storefront showcase:

```sh
swift run laur preview Examples/Showcase/Showcase.laur
```

Other commands:

```sh
swift run laur check Examples/ProductCard/ProductCard.laur   # errors and warnings
swift run laur fmt Examples/ProductCard/ProductCard.laur     # canonical formatting
swift test                                                   # run the test suite
```

## Sample data

Previews get their data from `samples.json` next to the `.laur` file, keyed by type name.
`.sample` uses the first entry, `.sample(name: "...")` overrides fields, and `.samples(3)`
gives a list.

```json
{
  "Product": [
    { "name": "Canvas Tote", "price": "$48.00", "photo": "bag.fill" }
  ]
}
```

`image` accepts an `https://` URL or an [SF Symbol](https://developer.apple.com/sf-symbols/) name.

## State and actions

A component owns `state`, computes `derived` values from it, and changes it only in
`action`s and button blocks. `bind` connects a field, toggle or child component to a
state value in both directions.

```laur
component QuantityPicker {
  state quantity: Number = 1

  view {
    stack(.horizontal, spacing: .md) {
      text("Quantity", style: .headline)
      spacer()
      Stepper(value: bind quantity)
    }
  }

  preview "one" {}
  preview "bulk" { quantity: 10 }
}

component Stepper(value: bind Number) {
  view {
    stack(.horizontal, spacing: .sm) {
      button("−", style: .secondary, enabled: value > 0) { value -= 1 }
      text("\(value)", style: .headline)
      button("+", style: .secondary) { value += 1 }
    }
  }

  preview "three" { value: 3 }
}
```

- `state` can be `String`, `Number` or `Bool`, and always has a starting value.
- `derived` values update whenever what they use changes, and can't be assigned.
- Statements are `x = ...`, `x += ...`, `x -= ...`, `someAction()`, `someLoad.reload()` and `if`.
- Parameters can't change unless declared `bind`; the checker explains how to fix it.
- Previews can set starting state: `preview "ready" { email: "a@b.com", agreed: true }`.
- Strings and lists have `count` and `isEmpty`; strings have `contains`, `hasPrefix`,
  `hasSuffix`, `lowercased()`, `uppercased()` and `trimmed()`; lists have `contains`.

## Loading data

Swift functions Laur can call are declared as a `service`. A `load` calls one when the
component appears, and `when` must handle all three outcomes, so no screen ships without
a loading and an error state.

```laur
service Orders {
  fetch(userId: String) -> [Order]
}

component OrderHistory(userId: String) {
  load orders = Orders.fetch(userId: userId)

  view {
    when orders {
      loading { spinner() }
      failed(error) {
        if error.kind == .network { text("You're offline") } else { text(error.message) }
        button("Try again") { orders.reload() }
      }
      loaded(items) {
        list(items) { order in OrderRow(order: order) }
      }
    }
  }

  preview "live"    { userId: "u_1" }
  preview "offline" { userId: "u_1", orders: .failed(.network) }
  preview "empty"   { userId: "u_1", orders: .loaded([]) }
}
```

In previews, loads never touch a real server. A load waits briefly and then returns the
sample data for its result type (`Order` in `samples.json`), so you see the loading
screen. A preview can pin an outcome with `.loading`, `.failed(.kind)`,
`.failed(.kind, "message")` or `.loaded(value)`, and `reload()` still works from there.
Errors have a `kind` (`.network`, `.notFound`, `.unauthorized`, `.server`, `.other`) and a
`message`. Real calls arrive with the Swift compiler.

## Context

Every component can read where it sits, without the parent passing anything down:

```laur
component ProductRow(product: Product) {
  view {
    stack(.horizontal, spacing: .sm) {
      if context.siblings.isFirst { badge("Top pick") }
      text(product.name)
      spacer()
      text("#\(context.siblings.index + 1) of \(context.siblings.count)", color: .tertiary)
    }
    if !context.siblings.isLast { divider() }
  }

  preview "middle" { product: .sample, context: .siblings(2, of: 5) }
}
```

| Group | Ordering | Fields |
| --- | --- | --- |
| `context.siblings` | position among the items in the nearest container (a list item, or a stack's children after `if`s) | `index`, `count`, `isFirst`, `isLast` |
| `context.reading` | reading order across the whole screen, depth-first | `index`, `count`, `isFirst` |
| `context.level` | nesting depth, and position among components at that depth, breadth-first | `depth`, `index`, `count` |
| `context.parent` | the containing component | `type`, `path` |

Indices start at 0. `context.reading.count` and `context.level.count` depend on the whole
screen, so they can be shown but can't be used in an `if` (the checker explains why).
`context.screen` (visibility, position on screen) comes with events in a later milestone.

A preview can place a component anywhere with `context: .siblings(2, of: 5)` or
`context: .reading(0, of: 3)`.

## Elements

| Element | Unlabeled argument | Labeled arguments |
| --- | --- | --- |
| `stack` | `.vertical` or `.horizontal` | `spacing`, `padding`, `alignment`, `background`, `corner` |
| `list` | a collection; the block names each item: `list(products) { product in ... }` | `axis`, `spacing` |
| `text` | the value to show | `style`, `color` |
| `image` | URL or symbol name | `aspect`, `corner`, `size` |
| `badge` | a short label | `color` |
| `field` | its label | `value: bind ...` (required), `secure`, `keyboard` |
| `toggle` | its label | `value: bind ...` (required) |
| `button` | its label; the block runs on tap: `button("Save") { save() }` | `style`, `enabled` |
| `spinner` | | |
| `spacer` | | |
| `divider` | | |

Views can also use `if`, `else if` and `else`. Expressions support `+ - * / %`,
`== != < <= > >=`, `&& || !`, parentheses, and string interpolation with `\( )`.

Components can also use other components from the same file, like `Price(amount: product.price)`.

Design tokens:

| Category | Tokens |
| --- | --- |
| spacing | `.none` `.xs` `.sm` `.md` `.lg` `.xl` |
| text style | `.largeTitle` `.title` `.headline` `.body` `.callout` `.caption` `.footnote` |
| color | `.primary` `.secondary` `.tertiary` `.accent` `.error` `.success` `.warning` `.surface` `.inverse` |
| corner | `.none` `.sm` `.md` `.lg` `.full` |
| aspect | `.square` `.wide` `.tall` `.fit` |
| image size | `.thumbnail` `.small` `.medium` `.large` |
| keyboard | `.text` `.email` `.number` `.phone` `.url` |
| button style | `.primary` `.secondary` `.plain` `.destructive` |
| error kind | `.network` `.notFound` `.unauthorized` `.server` `.other` |

## How it's built

```
Sources/
  LaurCore/      Lexer, syntax tree, parser, checker, printer. No UI code.
  LaurRuntime/   Resolver (decides what's on screen and assigns context), evaluator,
                 state store and action runner, SwiftUI renderer, theme and sample data.
  laur/          The command-line tool and the preview window.
Tests/
  LaurCoreTests/     Parser, expression, checker and error-message tests.
  LaurRuntimeTests/  Context, evaluation, state and action tests.
Examples/
  ProductCard/   Example 1 from the spec: a static card.
  ProductList/   Example 2: a list where each row knows its position.
  SignUp/        Example 3: an interactive form, a password meter and a stepper.
  OrderHistory/  Example 4: loading data, with loading, failure and empty states.
  Showcase/      A storefront built from five differently styled cards and lists.
```

The syntax tree in `LaurCore/AST.swift` is the center of everything: the previewer, the
checker and the formatter read it today, and the Swift compiler, language server and
design bar will read it later.

## Roadmap

Each milestone implements one example from the language spec:

1. ✅ Static components, previews, live reload
2. ✅ Lists, `if`, expressions and position context
3. ✅ State, bindings and actions
4. ✅ Async loading with `load` and `when`
5. Gates (A/B tests) with automatic exposure logging
6. Whole-component version swaps
7. Screens and navigation
8. Native Swift escape hatch
9. Typed events and logging
10. Slots
11. Compiling to Swift for release builds; iOS Simulator previewer; VS Code extension

## License

Apache 2.0
