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

> **Status: milestone 1, pre-alpha.** Laur parses and live-previews static components.
> State, gates, events, navigation and the Swift compiler are designed but not built yet.
> The syntax will change.

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

## Elements in milestone 1

| Element | Unlabeled argument | Labeled arguments |
| --- | --- | --- |
| `stack` | `.vertical` or `.horizontal` | `spacing`, `padding`, `alignment`, `background`, `corner` |
| `text` | the value to show | `style`, `color` |
| `image` | URL or symbol name | `aspect`, `corner`, `size` |
| `spacer` | | |
| `divider` | | |

Components can also use other components from the same file, like `Price(amount: product.price)`.

Design tokens:

| Category | Tokens |
| --- | --- |
| spacing | `.none` `.xs` `.sm` `.md` `.lg` `.xl` |
| text style | `.largeTitle` `.title` `.headline` `.body` `.callout` `.caption` `.footnote` |
| color | `.primary` `.secondary` `.tertiary` `.accent` `.error` `.success` `.surface` |
| corner | `.none` `.sm` `.md` `.lg` `.full` |
| aspect | `.square` `.wide` `.tall` `.fit` |
| image size | `.thumbnail` `.small` `.medium` `.large` |

## How it's built

```
Sources/
  LaurCore/      Lexer, syntax tree, parser, checker, printer. No UI code.
  LaurRuntime/   Interpreter that renders the syntax tree as SwiftUI, plus theme and sample data.
  laur/          The command-line tool and the preview window.
Tests/
  LaurCoreTests/ Parser and error-message tests.
Examples/
  ProductCard/   The first example from the spec.
```

The syntax tree in `LaurCore/AST.swift` is the center of everything: the previewer, the
checker and the formatter read it today, and the Swift compiler, language server and
design bar will read it later.

## Roadmap

Each milestone implements one example from the language spec:

1. ✅ Static components, previews, live reload
2. Lists and position context (`context.siblings`, `context.reading`, ...)
3. State, bindings and actions
4. Async loading with `load` and `when`
5. Gates (A/B tests) with automatic exposure logging
6. Whole-component version swaps
7. Screens and navigation
8. Native Swift escape hatch
9. Typed events and logging
10. Slots
11. Compiling to Swift for release builds; iOS Simulator previewer; VS Code extension

## License

Apache 2.0
