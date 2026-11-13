# Rendering flexspan documents

`showcase.qmd` demonstrates every flexspan feature and is set up for five
output formats. This page shows how to render each of them, with Quarto and
with plain pandoc, and what each format needs.

## Quick start

```bash
quarto render showcase.qmd              # all formats listed in the document
./render-all.sh                         # render all formats and check the results
```

| Format           | Command                                   | Output                  |
| ---------------- | ----------------------------------------- | ----------------------- |
| HTML             | `quarto render showcase.qmd --to html`     | `showcase.html`         |
| revealjs slides  | `quarto render showcase.qmd --to revealjs` | `showcase-slides.html`  |
| Word             | `quarto render showcase.qmd --to docx`     | `showcase.docx`         |
| Typst (PDF)      | `quarto render showcase.qmd --to typst`    | `showcase-typst.pdf`    |
| LaTeX (PDF)      | `quarto render showcase.qmd --to pdf`      | `showcase-latex.pdf`    |
| LaTeX source     | `quarto render showcase.qmd --to latex`    | `showcase.tex`          |

Formats that share a file extension need their own `output-file`, otherwise
they overwrite each other: the document sets it for revealjs
(`showcase-slides.html`), Typst (`showcase-typst.pdf`) and LaTeX
(`showcase-latex.pdf`). Both PDF formats are renamed because Quarto first
writes `showcase.pdf` and then moves it, which would delete a PDF of that name
left by the other format.

Requirements: Quarto 1.7 or later. PDF through LaTeX needs a TeX
distribution (`quarto install tinytex` is enough). Typst is bundled with
Quarto.

## What every document needs

```yaml
---
filters:
  - flexspan
flexspan:
  - left: "!!"
    color: red
---
```

Styled rules (`color`, `bg`, `bold`, `italic`, `underline`, `strike`, and
colours given as options) need nothing else in any format. The sections below
are only about **named rules** (`command:`) and `class:`, which you define
once per format. The showcase uses one named rule, `badge`:

```yaml
flexspan:
  - left: "%%"
    command: badge
```

```markdown
%%default%% %%passed%%(ok) %%careful%%(warn)
```

## HTML

```bash
quarto render showcase.qmd --to html
```

```yaml
format:
  html:
    css: showcase.css
```

A named rule becomes `<span class="badge">`; options become `data-`
attributes, which CSS can select:

```css
span.badge {
  display: inline-block;
  background-color: #1e90ff;
  color: white;
  font-size: 1em;
  font-weight: bold;
  line-height: 1.25;
  border-radius: 0.3em;
  padding: 0.1em 0.4em;
}
span.badge[data-ok]   { background-color: #2e8b57; }   /* %%text%%(ok)   */
span.badge[data-warn] { background-color: #d2691e; }   /* %%text%%(warn) */
```

> [!NOTE]
>
> Quarto's HTML theme is built on Bootstrap, which already has classes such as
> `.badge`, `.alert`, `.card` and `.btn`. If a rule uses one of these names,
> Bootstrap's own styling applies too (a smaller font, in the case of
> `.badge`). Write the selector as `span.badge` and set those properties
> yourself, as above, or pick a name Bootstrap does not use. revealjs has no
> such classes.

## revealjs

```bash
quarto render showcase.qmd --to revealjs
```

```yaml
format:
  revealjs:
    output-file: showcase-slides.html
    css: showcase.css
    scrollable: true
    smaller: true
```

Exactly like HTML: the same CSS file is used. Each `##` heading starts a
slide, and placeholders work in slide titles.

## Word (docx)

```bash
quarto render showcase.qmd --to docx
```

```yaml
format:
  docx:
    reference-doc: showcase-reference.docx
```

Colours, backgrounds and the other style keys are written directly into the
text and need **no** reference document.

A named rule (or `class:`) is applied as a Word *character style* with the
rule's name. Without a reference document the style exists but is empty, so
the text looks plain. To give it a look:

1. Create a reference document: `quarto pandoc -o my-reference.docx --print-default-data-file reference.docx`
2. Render your document once with `reference-doc: my-reference.docx`, open the
   result in Word or LibreOffice, modify the character style (`badge`), and
   save the file as your new `my-reference.docx`.

`showcase-reference.docx` was made this way and defines the character styles
`badge` and `note`. Options of a named rule (`(ok)`, `(warn)`) have no effect
in Word: a character style has a single look.

## Typst

```bash
quarto render showcase.qmd --to typst
```

```yaml
format:
  typst:
    output-file: showcase-typst.pdf
    keep-typ: true            # keep showcase.typ for inspection
    include-in-header:
      - text: |
          #let badge(..args, body) = {
            let tones = (info: rgb("#1e90ff"), ok: rgb("#2e8b57"), warn: rgb("#d2691e"))
            box(fill: tones.at(args.pos().at(0, default: "info")),
                inset: (x: 4pt), outset: (y: 3pt), radius: 3pt,
                text(fill: white, weight: "bold", body))
          }
```

A named rule becomes a function call: `%%passed%%(ok)` → `#badge("ok")[passed];`.
Bare options arrive as positional strings (`args.pos()`), `key=value` options
as named strings (`args.named()`). The function must be defined, otherwise
Typst stops with "unknown variable".

## LaTeX (PDF) and beamer

```bash
quarto render showcase.qmd --to pdf      # PDF
quarto render showcase.qmd --to latex    # only the .tex file
```

```yaml
format:
  pdf:
    output-file: showcase-latex.pdf
    keep-tex: true            # keep showcase.tex for inspection
    include-in-header:
      - text: |
          \definecolor{badgeinfo}{HTML}{1E90FF}
          \definecolor{badgeok}{HTML}{2E8B57}
          \definecolor{badgewarn}{HTML}{D2691E}
          \newcommand{\badge}[2][info]{\colorbox{badge#1}{\textcolor{white}{\textbf{#2}}}}
```

A named rule becomes `\badge[ok]{passed}`: the command takes one optional and
one mandatory argument. The same definitions work under `format: beamer`.

Symbols used as `content` (for example `→`) must exist in the document font.

## Plain pandoc

The filter does not need Quarto. Point pandoc at the Lua file; `-f markdown`
is only needed because of the `.qmd` extension.

```bash
F=_extensions/flexspan/flexspan.lua

pandoc -f markdown showcase.qmd -L $F -s --css showcase.css -o showcase.html
pandoc -f markdown showcase.qmd -L $F -s -t revealjs --css showcase.css -o showcase-slides.html
pandoc -f markdown showcase.qmd -L $F --reference-doc showcase-reference.docx -o showcase.docx
pandoc -f markdown showcase.qmd -L $F -H header.typ -o showcase-typst.pdf --pdf-engine typst
pandoc -f markdown showcase.qmd -L $F -H header.tex -o showcase-latex.pdf --pdf-engine lualatex
```

Pandoc ignores Quarto's `format:` section, so the definitions of the named
rules are passed on the command line instead: `--css` for HTML,
`--reference-doc` for Word, and `-H` with a file holding the `#let badge…`
(Typst) or `\newcommand{\badge}…` (LaTeX) lines shown above. Documents that
use only styled rules need none of these.

## Testing

`render-all.sh` renders the showcase to every format and checks that the
expected markup is in each result:

```bash
./render-all.sh                 # html revealjs docx typst pdf pandoc
./render-all.sh html docx       # only some formats
```

```
html -> showcase.html
  ok    rendered
  ok    text colour
  ok    colour inside bold
  ...
All checks passed.
```

The `pandoc` group runs the filter without Quarto (conversion only, no PDF
compilation). The script exits with a non-zero status when a check fails;
Quarto's output is kept in `render-all.log`.
