# 🌒 Flexspan: Quarto/Pandoc filter to assign new markup to text elements

This Pandoc Lua filter dynamically converts text enclosed in custom delimiters into LaTeX commands. It's designed for flexibility, allowing users to define their own placeholders and corresponding LaTeX commands through metadata.

## First steps

The main purpose of the `flexspan` extension is to let users create custom inline formatting in Pandoc-flavored Markdown. Users assign symbols to specific commands (classes).

First, define placeholders in the extension's metadata and assign each to a command. The extension scans paragraphs for these placeholders, then wraps the enclosed text in a new span with the specified class.

Suppose we have this definition in the metadata:

```markdown
---
flexspan:
  - left:: "--"
    right: "--"
    command: "mycommand"
---
```

Given the following passage in Markdown:

```markdown
This is a sample --enclosed text--
```

The extension will scan for the left and right placeholders ("--") and put the "enclosed text" inside a span, removing the placeholders accordingly.

The same can be directly achieved using the [Pandoc's span syntax](https://quarto.org/docs/authoring/markdown-basics.html#spans).

```markdown
This is a sample [enclosed text]{.mycommand}
```

This extension essentially provides a customizable and flexible markup notation that facilitates the writing of repetitive text formatting tasks.

### Types of documents

The extension generates spans for any type of output document format, but it is useful for composing [LaTeX/PDF documents](https://quarto.org/docs/output-formats/pdf-basics.html)or beamer presentations [Beamer presentations](https://quarto.org/docs/presentations/beamer.html).

## Usage and Configuration

This extension adds new text formatting markup via user-defined placeholders indicating the sentinel characters to the left and to the right, enclosing a single word or a sentence.

Configure it using the `flexspan` metadata key in your document's YAML front matter. You can define one or more filters, each with its own set of delimiters and command to decorate the span element.

> [!CAUTION]
>
> This works for text inside a single paragraph, i.e. without two newlines

### Metadata definitions

The placeholders should be defined in the extension metadata starting with the key `flexspan`.

The `flexspan` metadata block accepts a list of filters with the following keys:

- `left`: The left delimiter for your placeholder text (e.g., `[[`).
- `right`: The right delimiter. If omitted, it defaults to the same as `left`.
- `command`: The name of the LaTeX command to generate (without the leading backslash).
- `opts`: (Optional) A default set of options to be passed to the LaTeX command.

For the metadata definition:

```yaml
flexspan:
  - left: "[-"
    right: "-]"
    command: "texttt" # Mono font in LaTeX
  - left: "!!"
    right: "!!"
    command: "textbf" # Bold font in LaTeX
```

> [!IMPORTANT]
>
> Each filter definition starts with a dash (a list in YAML) and contains the left, right, and command attributes. You can define multiple filters.

We can write the following paragraph:

```markdown
This is a test of [-flexspan-] extension and it is !!nice!!
```

In a resulting LaTeX document this would be transformed to:

    This is a test of \texttt{flexspan} extension and it is \textbf{nice}

In an HTML document, the `flexspan` text would be enclosed in a span with `texttt` class, and the same holds for `nice`/`textbf`.

### Passing options to the command

The syntax can be extended. Users can add extra options after the placeholders by enclosing the text in parentheses, right after the right placeholder.

Suppose the `custombox` command accepts one optional argument, which is the background color. You can pass this argument by typing it in parentheses right after the right placeholder.

- Usage

```markdown
Using the new placeholders !!flexspan!!(LimeGreen) with options
```

- Rendered in LaTeX

      Using the new placeholders \command[LimeGreen]{flexspan} with options

Options are passed directly to the LaTeX command as an optional argument placed inside square brackets.

### Adding options to the metadata

Instead of passing options inside parenthesis, you can provide them in the metadata, with the parameter named `opts`.

- Metadata

```yaml
flexspan:
  - left: "-!"
    right: "!-"
    command: "custombox"
    opts: Cerulean
```

- Usage

```markdown
Using the new placeholders -!flexspan!- with opts: Cerulean
```

- Rendered in LaTeX

      Using the new placeholders \custombox[Cerulean]{flexspan} with opts: Cerulean

> [!NOTE]
>
> You can still pass options to a placeholder with default opts. In such cases, the inline option will override the default.

### Metadata rules and aliases

There are some rules for the filters definitions:

1. Mandatory parameters are 'left' and 'command'. If either is missing, the filter has no effect
2. You can omit the `right` parameter. If omitted, it defaults to the value of `left`
3. Some aliases can be used interchangeably to specify filter elements

| Parameter | Possible aliases   |
| --------- | ------------------ |
| left      | 'pre' or 'before'  |
| right     | 'pos' or 'after'   |
| command   | 'cmd' or 'class'   |
| opts      | 'opt' or 'options' |

## Creating new commands and placeholders in LaTeX

The user can define [new commands in LaTeX](https://www.overleaf.com/learn/latex/Commands#Commands_with_optional_parameters). These can be used with this extension, if they accept exactly two parameters: one optional (inside []) and one mandatory (inside {}). For example:

```latex
\renewcommand\custombox[2][Dandelion]{\colorbox{#1}{#2}}
```

Defines the `custombox` command that has two arguments ("[2]" part), and the optional argument has "Dandelion" as the default. In a LaTeX or Quarto document, this can be used directly in the document as:

    \custombox{Text inside a box}

Where the default background color will be "Dandelion" or:

    \custombox[Red]{Text inside a box}

for a box with red background.

In a Quarto, [new commands in LaTeX](https://www.overleaf.com/learn/latex/Commands#Commands_with_optional_parameters) can be specified in the document format metadata:

```yaml
format:
  pdf:
    include-in-header:
      - text: |
        \usepackage[dvipsnames]{xcolor}
        \newcommand{\custombox}[2][Dandelion]{\colorbox{#1}{#2}}
```

With this definition, we can create a new filter in the document metadata:

```yaml
flexspan:
  - left: "--"
    right: "--"
    command: "custombox"
  - left: "!!"
    right: "!!"
    command: "custombox"
    opts: "Red"
```

Now we can use:

```markdown
Using the new placeholders --flexspan-- and !!text in Red background!!
```

Instead of:

```markdown
Using the new placeholders \custombox{flexspan} and \custombox[Red]{text in Red background}
```

## Installation

### Quarto

    quarto install extension gpappasunb/flexspan

Add the filter to the document metadata:

```yaml
---
filters:
  - flexspan
---
```

Otherwise, you can place the `flexspan.lua` file in your project directory. In this case, the metadata changes

```yaml
---
filters:
  - flexspan.lua
---
```

> [!NOTE]
>
> Notice the `.lua` in the filename, because it is was not installed as a quarto extension

Also, for Quarto, you can add it to your `_quarto.yml` to be applied to all documents in the project directory.

```yaml
project:
  type: book
  filters:
    - flexspan # or flexspan.lua depending on the installation
```

### Pandoc

Save the file `_extensions/flexspan/flexspan.lua` to `~/.pandoc/filters` (default directory for
pandoc filters) or any other directory. Run using one of the following
syntaxes:

```bash
pandoc -s test.md -t latex -L flexspan.lua
pandoc -s test.md -t latex --lua-filter=flexspan.lua
pandoc -s test.md -t html -L ~/myfilters/flexspan.lua
```

The last alternative refers to the filter installed in a custom
location.

## Examples

Below are examples of how to use the defined placeholders in your Markdown document and the resulting LaTeX output.

### 1. Basic Usage

This example uses the `[[...]]` delimiters defined above.

**Markdown:**

```markdown
This is some text with a [[custom box]] inside it.
```

**Resulting LaTeX:**

```latex
This is some text with a \mycustombox{custom box} inside it.
```

### 2. Different Left and Right Delimiters

This example uses the `<<...>>` delimiters.

**Markdown:**

```markdown
Here we use <<different delimiters>>.
```

**Resulting LaTeX:**

```latex
Here we use \anothercommand[color=blue]{different delimiters}.
```

_Note: The `color=blue` option was specified in the metadata._

### 3. Inline Options

You can override or provide options directly in your Markdown by placing them in parentheses immediately after the closing delimiter.

**Markdown:**

```markdown
This is a [[custom box]](with-options) that has inline options.
```

**Resulting LaTeX:**

```latex
This is a \mycustombox[with-options]{custom box} that has inline options.
```

### 4. Inline Options with Different Delimiters

The same principle applies to any set of defined delimiters.

**Markdown:**

```markdown
This is another example with <<different delimiters>>(and-more-options).
```

**Resulting LaTeX:**

```latex
This is another example with \anothercommand[scale=1]{different delimiters}.
```

> [!NOTE]
>
> The inline `scale=1` will be used instead of the default from the metadata. (color=blue)

# Author

    Prof. Georgios Pappas Jr
    Computational Genomics group
    University of Brasilia (UnB) - Brazil
