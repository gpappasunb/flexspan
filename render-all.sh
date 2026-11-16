#!/usr/bin/env bash
# Renders showcase.qmd to every supported format and checks the results.
#
#   ./render-all.sh            render and check all formats
#   ./render-all.sh html docx  only the formats given
#
# Formats: html revealjs docx typst pdf pandoc
set -u
cd "$(dirname "$0")"

DOC=showcase.qmd
FILTER=_extensions/flexspan/flexspan.lua
LOG=render-all.log
: >"$LOG"

failures=0
ok() { printf '  \033[32mok\033[0m    %s\n' "$1"; }
fail() {
	printf '  \033[31mFAIL\033[0m  %s\n' "$1"
	failures=$((failures + 1))
}

# check <description> <command...>: passes when the command succeeds
check() {
	local desc=$1
	shift
	if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi
}

# render <format> <output file>
render() {
	printf '\n\033[1m%s\033[0m -> %s\n' "$1" "$2"
	rm -f "$2"
	if quarto render "$DOC" --to "$1" >>"$LOG" 2>&1 && [ -s "$2" ]; then
		ok "rendered"
	else
		fail "render failed (see $LOG)"
		return 1
	fi
}

# has <file> <text>: the file contains the text (line breaks count as spaces)
has() { tr -s '\n ' '  ' <"$1" | grep -qF -- "$2"; }
hasnt() { ! has "$1" "$2"; }
docx_xml() { unzip -p "$1" word/document.xml; }
docx_has() { docx_xml "$1" | grep -qF -- "$2"; }

test_html() {
	local out=showcase.html
	render html $out || return
	check "text colour" has $out '<span style="color: red;"><strong>red</strong></span>'
	check "reference table: syntax kept, result rendered" has $out '<td><code>!!text!!</code></td> <td>text colour: bold red</td> <td><span style="color: red;"><strong>text</strong></span></td>'
	check "colour inside bold" has $out '<strong>Bold text with a <span style="color: red;"><strong>red</strong></span> word.</strong>'
	check "background" has $out 'style="background-color: yellow;"'
	check "inline options" has $out 'style="color: white; background-color: navy;"'
	check "heading" has $out 'Headings with <span style="color: red;"><strong>colour</strong></span>'
	check "class + style" has $out '<span class="note" style="color: #1e90ff;">'
	check "named rule + option" has $out '<span class="badge" data-ok="">passed</span>'
	check "inline code" has $out '<code>ls -la</code>'
	check "inline code + background" has $out '<span style="background-color: gold;"><code>highlighted code</code></span>'
	check "exact symbol" has $out '<strong>→</strong>'
	check "fixed content" has $out 'REDACTED'
	check "format block: base rule" has $out 'A star <span style="color: goldenrod;">★</span>'
	check "fixed content replaces text" hasnt $out 'hunter2]]</p>'
	check "word boundary respected" has $out 'Wow!! Great!!'
	check "skipspan respected" has $out '!!protected by a span!!'
}

test_revealjs() {
	local out=showcase-slides.html
	render revealjs $out || return
	check "is a slide deck" has $out 'class="reveal"'
	check "colour inside emphasis" has $out '<em>Emphasis with a <span style="color: red;"><strong>red</strong></span> word.</em>'
	check "slide title" has $out 'Headings with <span style="color: red;"><strong>colour</strong></span>'
	check "named rule" has $out '<span class="badge" data-warn="">careful</span>'
	check "format block: revealjs on top of base" has $out 'A star <span class="slide-star" style="color: goldenrod;">★</span>'
}

test_docx() {
	local out=showcase.docx
	render docx $out || return
	check "document.xml is well-formed" python3 -c "
import zipfile, xml.dom.minidom as m
m.parseString(zipfile.ZipFile('$out').read('word/document.xml'))"
	check "text colour" docx_has $out '<w:rPr><w:b/><w:bCs/><w:color w:val="FF0000"/></w:rPr><w:t xml:space="preserve">red</w:t>'
	check "colour + background inside bold" docx_has $out '<w:b/><w:bCs/><w:color w:val="FF0000"/><w:shd w:val="clear" w:color="auto" w:fill="FFFF00"/>'
	check "colour inside emphasis" docx_has $out '<w:b/><w:bCs/><w:i/><w:iCs/><w:color w:val="FF0000"/>'
	check "background" docx_has $out 'w:fill="FFFF00"'
	check "colour + background" docx_has $out '<w:color w:val="FFFFFF"/><w:shd w:val="clear" w:color="auto" w:fill="000080"/>'
	check "inline code" docx_has $out '<w:rStyle w:val="VerbatimChar" /></w:rPr><w:t xml:space="preserve">ls -la</w:t>'
	check "underline" docx_has $out '<w:u w:val="single"/>'
	check "format block: base rule" docx_has $out '<w:color w:val="DAA520"/></w:rPr><w:t xml:space="preserve">★</w:t>'
	check "named rule uses character style" docx_has $out '<w:rStyle w:val="badge"'
	check "character style comes from reference doc" sh -c "unzip -p $out word/styles.xml | grep -q 'w:styleId=\"badge\".*1E90FF'"
}

test_typst() {
	local out=showcase-typst.pdf src=showcase.typ
	render typst $out || return
	check "text colour" has $src '#text(fill: rgb("#ff0000"))[#strong[red]];'
	check "colour inside bold" has $src '#strong[Bold text with a #text(fill: rgb("#ff0000"))[#strong[red]]; word.]'
	check "background" has $src '#highlight(fill: rgb("#ffff00"))['
	# pandoc writes `ls -la`; Quarto's Typst template writes #NormalTok("ls -la");
	check "inline code" grep -qE 'Run (`ls -la`|#NormalTok\("ls -la"\);)' $src
	check "named rule + option" has $src '#badge("ok")[passed];'
	check "hand-written span" has $src '#badge[span];'
	check "format block: typst content" has $src 'A star #text(fill: rgb("#daa520"))[✦];'
	if command -v pdftotext >/dev/null; then
		check "PDF text: fixed content" sh -c "pdftotext $out - | grep -q REDACTED"
	fi
}

test_pdf() {
	local out=showcase-latex.pdf src=showcase.tex
	render pdf $out || return
	check "text colour" has $src '\textcolor[HTML]{FF0000}{\textbf{red}}'
	check "colour inside bold" has $src '\textbf{Bold text with a \textcolor[HTML]{FF0000}{\textbf{red}} word.}'
	check "background" has $src '\colorbox[HTML]{FFFF00}{'
	check "inline code" has $src '\texttt{ls\ -la}'
	check "named rule + option" has $src '\badge[ok]{passed}'
	check "hand-written span" has $src '\badge{span}'
	check "format block: latex command, colour removed" has $src 'A star \fstar{} that'
	if command -v pdftotext >/dev/null; then
		check "PDF text: fixed content" sh -c "pdftotext $out - | grep -q REDACTED"
	fi
}

# The filter also works with plain pandoc (no Quarto)
test_pandoc() {
	printf '\n\033[1mpandoc\033[0m (without Quarto)\n'
	local tmp
	tmp=$(mktemp -d)
	for fmt in html latex typst docx; do
		if pandoc -f markdown "$DOC" -L "$FILTER" -t $fmt -o "$tmp/out.$fmt" 2>>"$LOG"; then
			ok "pandoc -t $fmt"
		else
			fail "pandoc -t $fmt"
		fi
	done
	check "html" has "$tmp/out.html" '<span style="color: red;"><strong>red</strong></span>'
	check "latex" has "$tmp/out.latex" '\textcolor[HTML]{FF0000}{\textbf{red}}'
	check "typst" has "$tmp/out.typst" '#text(fill: rgb("#ff0000"))[#strong[red]];'
	check "docx" docx_has "$tmp/out.docx" '<w:color w:val="FF0000"/>'
	check "no warnings from the filter" hasnt "$LOG" '[flexspan]'
	rm -rf "$tmp"
}

[ $# -eq 0 ] && set -- html revealjs docx typst pdf pandoc
for fmt in "$@"; do
	case $fmt in
	html | revealjs | docx | typst | pdf | pandoc) "test_$fmt" ;;
	latex) test_pdf ;;
	*) fail "unknown format '$fmt'" ;;
	esac
done

echo
if [ "$failures" -eq 0 ]; then
	printf '\033[32mAll checks passed.\033[0m\n'
else
	printf '\033[31m%d check(s) failed.\033[0m Details in %s\n' "$failures" "$LOG"
	exit 1
fi
