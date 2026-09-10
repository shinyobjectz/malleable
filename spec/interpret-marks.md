# interpret — how a workspace extends the reading, and why it cannot smuggle a regex

## The problem this solves

A workspace states a rule in prose; Build derives it into the ontology and renders it into
`.work/rules/rules.lua`. Five kinds — seam, notation, row, law, lint. Three of them
(`seam`, `notation`, `row`) are driven by a raw regex in the `pattern` field today.

That collides with mar-4o07, ruled 2026-09-09: no reader may key off a phrase, an exact
word, a closed idiom list or a character position. Every reading comes from the models and
the map, as far as is physically possible.

But the collision is not total, and the measurement says where the line is. Five rules in
the whole corpus carry a pattern:

| workspace | kind | pattern | what it is |
|---|---|---|---|
| demo/site-status | notation | `\$[A-Z][A-Z0-9_]*` | invented notation |
| fixtures | notation | `^\$[A-Za-z_][A-Za-z0-9_]*$` | invented notation |
| gen-harbor-room | notation | `\$tired` | invented notation |
| fixtures | seam | `(?m)^\d{4}-\d{2}-\d{2}\b` | a formatted token |
| fixtures | row | `[Tt]he board` | **ordinary English** |

The first four are marks the author invented and then defined in prose. The parser sees
nothing there and never will — `$tired` is not language, it is orthography, and no
improvement to the map can recover a meaning that was decreed rather than said. Refusing
these leaves a writer no way to define their own symbol.

The fifth is a definite description. Binding one to its referent is what the coreference
layer is for. It is a proxy in exactly mar-4o07's sense, and it is already brittle: the
corpus contains "the Boardroom", which survives only because a capital B misses the
pattern.

## The rule

**A declared mark must be invisible to the map.** If the parse aligns a graph node to the
span a mark matches, that span is language, and the reading belongs to the map — not to a
pattern the workspace shipped.

## How it is enforced — two gates, because one is not enough

### Gate 1, at declaration: there is no pattern to write

`interpret` never accepts a regex, a glob, or any string that is compiled into a matcher.
The surface has no field that could hold one. A mark is declared out of parts:

```lua
interpret.mark "hand-set value" {
  lead  = "$",                  -- REQUIRED: exactly one non-alphanumeric character
  shape = interpret.SHOUTED,    -- one of the shape constants, or omitted for a literal
  means = interpret.VALUE,      -- what the map should read it as
}

interpret.mark "tired" {
  lead  = "$",
  word  = "tired",              -- a literal that follows the lead
  means = interpret.FLAG,
}

interpret.seam "log date" {
  at    = interpret.LINE_START,
  shape = interpret.DATE,
}
```

Four properties make this hard to get wrong, deliberately:

1. **`lead` is required and must be a single non-alphanumeric character.** A mark has to
   begin with a symbol the language does not use. `[Tt]he board` has no lead and cannot be
   expressed — there is no field to put it in. This is the whole trick: the common mistake
   is not discouraged, it is unrepresentable.

2. **`shape` is a CONSTANT, not a string.** `interpret.SHOUTED`, `interpret.DATE`,
   `interpret.NUMBER`, `interpret.WORD` are tables held by identity. A typo yields `nil`
   and `nil` is refused by name, loudly, at declaration. A string field would let an agent
   write `shape = "[A-Za-z ]+"` and have it silently work; a constant cannot carry a
   payload. There is no `shape = interpret.ANYTHING`, and no way to compose two shapes,
   because a mark that needs alternation is a mark that is trying to be a grammar.

3. **`word`, when given, is a literal and is escaped.** It is never compiled as a pattern.
   Every regex metacharacter in it is quoted before it reaches a matcher, so `.` means a
   full stop and `|` means a pipe. An author cannot reach the engine through the one field
   that takes free text.

4. **The whole extent must contain a non-letter.** Checked after assembly, so a lead of
   `-` plus a `word` of `the-board` still fails: strip the lead and the punctuation and if
   what remains is ordinary English, it is refused with the message naming the reference
   layer as the place it belongs.

### Gate 2, at Build: the map is asked whether it can already see it

The syntax gate cannot catch everything — `$` followed by a word that happens to be a
sentence in some page is conceivable. So the rendered mark is tested against the pages it
would fire on, and a mark whose span the parse ALIGNED TO A GRAPH NODE is refused, with the
aligned word named in the message.

This is the same shape as the reader-proxy ratchet: a rule nobody can fail is a rule nobody
keeps. Gate 1 makes the error hard to write; gate 2 makes it impossible to ship.

## What replaces the refused case

A `row` rule that wants to bind a phrase to an address states the phrase and the address,
and the MAP does the matching through the reference layer:

```lua
interpret.means "the board" {
  is = "quiet-site.latest_board",
}
```

No pattern, no capitalisation to get wrong, no "the Boardroom" near-miss: the coreference
layer decides what refers to what, and this rule supplies only the answer for the referent
it names. It is weaker than a regex today, because coref is weak today (mar-86nr is a
pronoun with no chain). That weakness is the correct pressure — it pushes on the layer that
owes the reading instead of routing around it.

## Naming

`interpret` is the prefix: `interpret.mark`, `interpret.seam`, `interpret.means`,
`interpret.law`, `interpret.lint`. Checked free in the vocabulary 2026-09-10, as are
`compiler`, `mapper`, `transpiler` and `lens`. `compiler` is spoken for in practice by
compile.rs; `mapper` collides with the map, which is the layer itself; `transpiler` is
inaccurate, since nothing here is source-to-source.

`agent.foo` declares behaviour, `interpret.foo` declares reading. One prefix each.
