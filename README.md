# 🌒 Flexspan: Quarto/Pandoc filter to assign new markup to text elements

Flexspan lets you invent your own inline markup. You choose a pair of
delimiters in the document metadata and say what the enclosed text should
become: coloured text, highlighted text, a LaTeX command, a Typst function, or
a CSS class.

```yaml
flexspan:
  - left: "!!"
    color: red
```

```markdown
A !!red!! word, **bold text with a !!red!! word** and *!!red emphasis!!*.
```

That is all that is needed: the example above gives red text in HTML, PDF
(LaTeX), Typst, Word (docx), revealjs and beamer, with nothing else to define.

## Installation

flexspan is self-contained: no other extension is needed. (For icons it can
optionally be paired with fontawesome-raw, see
[Icons](#icons-using-flexspan-together-with-fontawesome-raw).)

### Quarto

    quarto install extension gpappasunb/flexspan

```yaml
---
filters:
  - flexspan
---
```

To apply it to every document of a project, add it to `_quarto.yml`:

```yaml
project:
  type: book
filters:
  - flexspan
```

### Inside another extension

Flexspan can be embedded in another extension, for example a slide theme, so
that documents using that theme get flexspan without installing it. From the
directory that holds the other extension's `_extensions/` folder:

```bash
quarto add gpappasunb/flexspan --embed unb-slides
```

or, from a local copy of this repository (packages only the filter, not the
test files):

```bash
./embed.sh ~/quarto/extensions/unb-slides unb-slides
```

Then list it among the host extension's filters, in its `_extension.yml`:

```yaml
contributes:
  formats:
    revealjs:
      filters:
        - flexspan
```

The filter does nothing in documents without a `flexspan:` metadata key, so it
is safe to include by default. Run `embed.sh` again to update the embedded copy.

### Pandoc

Copy `_extensions/flexspan/flexspan.lua` to `~/.pandoc/filters` (or anywhere
else) and run:

```bash
pandoc -s doc.md -t html  -L flexspan.lua
pandoc -s doc.md -o doc.docx --lua-filter=flexspan.lua
```

Pandoc 3.0 or later is required.

## Built-in rules

These rules work without any metadata (since version 2.2; `++` since 2.3):

| Write | Result |
|-------|--------|
| `!!text!!` | red, bold |
| `==text==` | yellow background |
| `++text++` | sea green (`#2e8b57`), bold |
| `%[ls -la]` | inline code, like backticks |
| `-=text=-(blue)` | no style of its own: the style is given as options, e.g. `-=text=-(white, bg=navy, bold)` |
| `-=text=-r` `=-g` `=-b` `=-c` `=-p` `=-o` | shortcuts: bold red, green, blue, aqua, purple, orange |
| `+-text-+` | underline |
| `!-text-!` | strike-out, grey |
| `((text))` | class `note` (HTML) / character style (Word), blue italic |

Your own rules are added to these. A rule with the same `left` **and**
`right` delimiters as a built-in one replaces it completely (keys are not
merged), so this makes `!!` blue and not bold:

```yaml
flexspan:
  - left: "!!"
    color: blue
```

The same holds between layers: a format's rules (for example from an
extension such as unb-slides) replace the built-in ones, and the rules of the
project (`_quarto.yml`) and of the document replace those of the format. The
last definition wins.

To remove one rule, repeat its delimiters with `disable: true`; to remove all
built-in rules, set `flexspan-defaults: false`:

```yaml
flexspan-defaults: false        # no built-in rules at all
flexspan:
  - left: "(("
    right: "))"
    disable: true               # or remove just this one
```

## Two kinds of rules

Every entry of the `flexspan` list is a rule. A rule always has a `left`
delimiter; `right` defaults to the same string.

### 1. Styled rules: the filter does the formatting

Give the rule one or more style keys. They work in every output format.

| Key         | Value                    |
| ----------- | ------------------------ |
| `color`     | text colour              |
| `bg`        | background colour        |
| `bold`      | `true` / `false`         |
| `italic`    | `true` / `false`         |
| `underline` | `true` / `false`         |
| `strike`    | `true` / `false`         |
| `code`      | `true` / `false`: inline code, like backticks |

```yaml
flexspan:
  - left: "!!"
    color: red
  - left: "=="
    bg: yellow
  - left: "(("
    right: "))"
    color: "#1e90ff"
    bold: true
```

```markdown
!!red!!, ==highlighted==, ((blue and bold)), !!red ==and highlighted== red!!
```

A rule with **no style at all** takes its colour where it is used. Options are
written in parentheses right after the closing delimiter:

```yaml
flexspan:
  - left: "-="
    right: "=-"
```

```markdown
-=green=-(green)  -=white on navy=-(white, bg=navy)  -=loud=-(orange, bold)  -=hex=-(#8a2be2)
```

In the options of a styled rule a bare word is the text colour; `color=`,
`bg=`, `bold`, `italic`, `underline`, `strike` and `code` are also understood.
Options given in the text replace the rule's default `opts`; they are applied
on top of the rule's style keys.

#### Inline code

`code: true` gives a placeholder that behaves like backticks. The closing
delimiter can be a single character:

```yaml
flexspan:
  - left: "%["
    right: "]"
    code: true
```

```markdown
Run %[ls -la] and then %[git status].
```

`code` combines with the other style keys and can be given as an option:
`-=text=-(code, bg=gold)`.

Unlike real backticks, the text is read by Markdown first, so it is not fully
verbatim: `%[a*b*c]` loses its asterisks and `%[x[1]]` ends at the first `]`.
Typographic quotes, dashes and ellipses are turned back into `"`, `--` and
`...`. Other placeholders are not applied inside. Use real backticks for code
that contains Markdown characters.

#### Colours

Use a [CSS colour name](https://developer.mozilla.org/en-US/docs/Web/CSS/named-color)
(`red`, `DodgerBlue`, `darkgreen`, …) or a hex value (`#f00`, `#1e90ff`). These
are converted for each format, so the colour is identical in HTML, PDF, Typst
and Word.

Anything else is passed on unchanged, which lets you use format specific
colours when you only target one format: `red!30` or `Cerulean` (LaTeX
xcolor), `luma(80)` (Typst), `rgb(0 0 0 / 50%)` (CSS). Word accepts only CSS
names and hex values; other colours are ignored there, with a warning.

### 2. Named rules: you define what the name means

With `command` the text is handed to something you define yourself.

```yaml
flexspan:
  - left: "%%"
    command: custombox
    opts: orange          # optional default options
```

```markdown
%%boxed%% and %%boxed%%(lime)
```

| Output        | Result                                             | You provide                 |
| ------------- | -------------------------------------------------- | --------------------------- |
| LaTeX, beamer | `\custombox[lime]{boxed}`                          | the LaTeX command           |
| Typst         | `#custombox("lime")[boxed];`                       | the Typst function          |
| HTML, revealjs| `<span class="custombox" data-lime="">boxed</span>`| CSS for `.custombox`        |
| Word          | text with character style `custombox`              | the style, in the reference document |

Options of a named rule are passed to the command untouched:

- LaTeX: exactly as typed, as the optional argument: `(fg=red,scale=2)` →
  `\cmd[fg=red,scale=2]{…}`.
- Typst: bare words become positional strings and `key=value` named strings:
  `(lime, scale=2)` → `#cmd("lime", scale: "2")[…]`.
- HTML: `key=value` becomes `data-key="value"`, a bare word becomes an empty
  `data-word` attribute. Select them in CSS with `.cmd[data-lime]` or
  `.cmd[data-fg="red"]`.

Example definitions for the rule above:

```yaml
format:
  html:
    css: styles.css       # .custombox { background: orange } .custombox[data-lime] { background: lime }
  pdf:
    include-in-header:
      - text: |
          \newcommand{\custombox}[2][orange]{\colorbox{#1}{#2}}
  typst:
    include-in-header:
      - text: |
          #let custombox(..args, body) = box(
            fill: eval(args.pos().at(0, default: "orange")),
            inset: (x: 3pt), outset: (y: 3pt), body)
```

A LaTeX command used this way must take one optional and one mandatory
argument (`\newcommand{\name}[2][default]{…}`).

> [!IMPORTANT]
>
> A `command` must exist in every format you render to. An undefined command
> stops LaTeX and Typst with an error. HTML and Word simply show plain text.

Use `class` instead of `command` when you only want a hook for CSS (or a Word
character style) and no LaTeX/Typst command. It combines with style keys:

```yaml
  - left: "(("
    right: "))"
    class: note       # <span class="note" style="color: #1e90ff;">
    color: "#1e90ff"  # plain coloured text in LaTeX and Typst
```

Hand-written spans work too, for any class that is the `command` of a rule:
`[text]{.hl fg=red}` gives `\hl[fg=red]{text}` in LaTeX and
`#hl(fg: "red")[text];` in Typst. (Pandoc's span syntax only accepts
`key=value` attributes, not bare words.)

## All metadata keys

| Key         | Aliases                               | Meaning                                              |
| ----------- | ------------------------------------- | ---------------------------------------------------- |
| `left`      | `pre`, `before`, `open`               | opening delimiter (required)                         |
| `right`     | `pos`, `post`, `after`, `close`       | closing delimiter (default: same as `left`)          |
| `color`     | `fg`                                  | text colour                                          |
| `bg`        | `background`                          | background colour                                    |
| `bold`, `italic`, `underline`, `strike` |           | `true` / `false`                                     |
| `code`      |                                       | `true` / `false`: inline code, like backticks        |
| `command`   | `cmd`                                 | LaTeX command / Typst function; also used as class   |
| `class`     |                                       | HTML class / Word character style                    |
| `opts`      | `opt`, `options`                      | default options                                      |
| `content`   | `contents`, `val`, `arg`              | fixed content; the enclosed text is discarded        |
| `exact`     | `single`, `one`, `join`, `contiguous` | the delimiters are written together, with no content |
| `disable`   | `disabled`, `off`                     | `true`: remove the rule with these delimiters ([built-in rules](#built-in-rules)) |
| `latex`, `html`, `typst`, `docx`, `beamer`, `revealjs` |  | map of the keys above, used for that output format only ([format blocks](#format-blocks)) |

Unknown keys and missing delimiters are reported on the terminal
(`[flexspan] rule #3: unknown key 'comand' ignored`). A repeated delimiter
pair is not an error: the later rule replaces the earlier one.

### Symbols: `exact` and `content`

`exact` rules match the two delimiters written together. They are meant for
symbols and icons:

```yaml
flexspan:
  - left: "-"
    right: "\\>"
    command: iconarrow
    exact: true
```

```markdown
-> next step       →  \iconarrow{} next step
->(fg=red) alert   →  \iconarrow[fg=red]{} alert
```

`content` replaces whatever is enclosed with a fixed text.

### Format blocks

A LaTeX command such as `\iconbullet` means nothing in HTML or Word. A rule
can therefore hold a block named after an output format; the keys inside it
replace those of the rule when rendering to that format:

```yaml
flexspan:
  - left: "::"
    right: ":*"
    exact: true
    content: "●"            # every format ...
    color: navy
    latex:                  # ... except LaTeX and beamer: \iconbullet{}
      command: iconbullet
      content: ""
      color: ""
  - left: "!!"
    command: hlred          # LaTeX command, Typst function, Word style
    html:                   # HTML: no class, plain styling instead
      command: ""
      color: red
      bold: true
```

| Block                              | Applies to                                         |
| ---------------------------------- | -------------------------------------------------- |
| `latex`, `typst`, `docx`           | that output family (`latex` includes beamer / pdf) |
| `html`                             | every other format (html, revealjs, epub, ...)     |
| `beamer`, `revealjs`               | that writer only, on top of `latex` / `html`       |

- A block accepts every key except the delimiters and `exact`: what is
  matched is the same in all formats.
- An empty value removes `command`, `class`, `opts`, `color` or `bg`;
  `content: ""` means "no content"; booleans are switched off with `false`.
- Blocks for other formats are ignored.

### Icons: using flexspan together with fontawesome-raw

flexspan has no dependencies: it never needs another extension, and nothing
below is required to use it. It combines well, however, with
`fontawesome-raw`, a separate Quarto extension installed on its own: a
filter that turns raw FontAwesome glyph characters into real icons. Used
together, a short symbol such as `::v` becomes an icon:

```yaml
filters:
  - flexspan            # first: writes the glyph
  - fontawesome-raw     # second: turns the glyph into an icon

flexspan:
  - left: "::"
    right: "v"
    exact: true
    content: "\uf00c"         # FontAwesome "check"
  - left: "::"
    right: "!"
    exact: true
    content: "\uf071"         # FontAwesome "triangle-exclamation"
    color: crimson
```

```markdown
Done ::v     Careful ::!     A green check: ::v(green)
```

The glyph is written as a YAML escape (`"\uf00c"`, double quotes required) or
pasted as the character itself; the code of each icon is its "Unicode" value
on fontawesome.com.

What you get:

| Output              | Result                                                       |
| ------------------- | ------------------------------------------------------------ |
| HTML, revealjs      | `<i class="fa-solid fa-check">`, FontAwesome CSS loaded       |
| LaTeX, beamer (pdf) | `\faIcon{check}`, package `fontawesome6` loaded              |
| Typst, Word         | not handled by fontawesome-raw: the raw glyph is left as is  |

Things to know:

- **Order matters.** `flexspan` must be listed before `fontawesome-raw`.
  The other way round the icons disappear: fontawesome-raw converts the glyph
  inside the rule itself before flexspan reads it.
- **Colours.** `color`, `bg` and inline options (`::v(green)`) are applied by
  flexspan around the icon. This needs fontawesome-raw 1.0.1 or later; version
  1.0.0 drops the colour.
- **Typst and Word.** Give those formats something they can show with a
  [format block](#format-blocks):

  ```yaml
  - left: "::"
    right: "v"
    exact: true
    content: "\uf00c"
    typst: { content: "✔" }
    docx: { content: "✔" }
  ```

- **Without fontawesome-raw** the same rules still match, but the glyph is a
  private-use character that shows as an empty box. Use ordinary characters
  (`content: "✔"`, `"→"`, `"⚠"`) when you do not want the second filter.
- **Embedding.** An extension that ships such rules must embed both filters
  (see [Inside another extension](#inside-another-extension)) and list them in
  that order.

## Where it works, and where it does not

Placeholders are recognised anywhere inline text occurs: paragraphs, headings,
lists, table cells, captions, footnotes, and inside bold, emphasis, links and
other spans. They can be nested, and the enclosed text can contain any inline
formatting.

Rules of the game:

- **Same block.** Both delimiters must be in the same paragraph (or heading,
  cell, …).
- **Same level.** A placeholder cannot start outside bold/emphasis and end
  inside it: `!!red **bold!! text**` is left alone; write
  `!!red **bold**!! **text**`.
- **Word boundaries.** An opening delimiter must not follow a letter or digit;
  a closing delimiter must not be followed by one. `Wow!! Great!!` is therefore
  not a placeholder, while `(!!this!!),` is.
- **Nearest closing delimiter wins.** Several rules may share the same `left`
  with different `right` delimiters (`::` … `:o`, `::` … `:#`). At the same
  position the longest delimiter wins, so `---` is tried before `--`.
- **Options** must touch the closing delimiter: `!!text!!(blue)`, not
  `!!text!! (blue)`. They may contain spaces.
- **Code and math** are never touched. To protect ordinary text, put it in a
  span or div with the class `skipspan`: `[!!literal!!]{.skipspan}`.
- The document title and other metadata are not processed.

### Choosing delimiters

Delimiters are read by pandoc's Markdown parser before the filter sees them,
both in the metadata and in the text. Some characters therefore cannot work:

| Avoid                          | Because                                                        |
| ------------------------------ | -------------------------------------------------------------- |
| `[[text]](opts)`, `[-x-](opts)`| `[…](…)` is a Markdown link. Brackets are fine *without* options |
| `<<text>>`                     | `<text>` is read as an HTML tag                                |
| `@@text@@`                     | `@text` is a citation                                          |
| `**`, `__`, `~~`, `^`, `` ` ``, `$` | Markdown emphasis, strikeout, superscript, code, math    |
| `"` and `'`                    | turned into typographic quotes                                 |

Good choices are pairs of punctuation such as `!!`, `==`, `%%`, `++`, `::`,
`-=` … `=-`, `+:` … `:+`, `((` … `))`.

A delimiter that is Markdown syntax *on its own* must be escaped in the YAML
with two backslashes: `right: "\\>"`, `left: "\\<"`. The filter warns when a
delimiter turns out empty.

`--` and `---` work as delimiters even though pandoc converts them to dashes,
because the metadata is converted the same way.

## Output formats

| Format                    | Colour / background                        | bold, italic, … | `command`        | `class`         |
| ------------------------- | ------------------------------------------ | --------------- | ---------------- | --------------- |
| HTML, revealjs, epub      | `style="color: …; background-color: …"`    | native          | span class       | span class      |
| LaTeX, beamer (PDF)       | `\textcolor`, `\colorbox` (xcolor)         | native          | `\command[…]{…}` | span (no effect)|
| Typst                     | `#text(fill: …)`, `#highlight(fill: …)`    | native          | `#command(…)[…]` | no effect       |
| Word (docx)               | run colour and shading                     | native          | character style  | character style |
| other (odt, pptx, …)      | not supported                              | native          | no effect        | no effect       |

Notes:

- LaTeX: `\colorbox` does not break across lines; keep highlighted passages
  short. xcolor is loaded by the default pandoc and Quarto templates.
- Word: colours are written directly into the text runs, so no reference
  document is needed. Named rules use a character style with the rule's name;
  pandoc creates it empty, and you can give it a look in your reference
  document.

## Changes in version 2.3

- New built-in rule `++text++`: sea green, bold. "C++" is not affected: an
  opening delimiter right after a letter is not matched.

## Changes in version 2.2

- [Built-in rules](#built-in-rules): `!!`, `==`, `%[ ]`, `-= =-` with the
  colour shortcuts `=-r` … `=-o`, `+- -+`, `!- -!` and `(( ))` work without
  metadata. Turn them off with `flexspan-defaults: false`.
- A rule with the same delimiters as an earlier one now replaces it (it used
  to be ignored with a warning). The document has the last word.
- `disable: true` removes a rule.

## Changes in version 2.1

- [Format blocks](#format-blocks): a rule can have different keys for each
  output format (`latex`, `html`, `typst`, `docx`, `beamer`, `revealjs`).

## Changes in version 2

- Placeholders are found inside bold, emphasis, links, headings and every
  other inline container, not only at the top level of paragraphs.
- New style keys `color`, `bg`, `bold`, `italic`, `underline`, `strike`, with
  native output for HTML, LaTeX, Typst and Word.
- `command` is no longer required. `class` is no longer an alias of `command`:
  it sets the HTML class only and never produces a LaTeX command.
- `command` now also produces a function call in Typst.
- Options keep the order in which they were typed and may contain spaces.
- Delimiters next to letters or digits are no longer matched.
- `exact: false` is honoured (any value used to mean true).
- Nothing is printed on standard output any more; problems in the metadata are
  reported on standard error.

## Examples

- `template.qmd` is a short starting point.
- `showcase.qmd` demonstrates every feature and renders to HTML, revealjs,
  Word, Typst and LaTeX/PDF. [README-render.md](README-render.md) explains how
  to render each format and what each one needs.
- `./render-all.sh` renders the showcase to all formats and checks the results.

```bash
quarto render showcase.qmd
```

# Author

    Prof. Georgios Pappas Jr
    Computational Genomics group
    University of Brasilia (UnB) - Brazil
