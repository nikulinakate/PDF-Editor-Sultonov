# Native PDF engine roadmap

## Milestone 1 — native editor foundation (implemented)

Own transactional command layer over PDFKit; annotation and text-widget persistence; bounded undo/redo; page operations; original-preserving import; autosave/export; initial source-stream inspection; current-page OCR. App and tests have no commercial SDK dependency.

## Implemented source-text subset

A classic-xref object reader/writer, bounded Flate decoder, font ToUnicode/WinAnsi decoder and page text-operator selection now support horizontal single-line replacement/deletion. The app embeds replacement glyphs through CoreText, imports and renames resources, removes old operands, isolates shared page streams and rewrites reachable objects. UI selection, Unicode replacement, repeated editing and Undo/Redo are connected. Unsupported structures/text states fail explicitly. This does not implement secure redaction.

## Milestone 2 — broader writable source object model

- Parse PDF objects, references, resource dictionaries, compressed/object streams and cross-reference tables/streams.
- Resolve inherited page resources and nested Form XObjects; preserve graphics state, matrices, clipping and reused resources.
- Decode simple/CID fonts, encodings, ToUnicode CMaps, embedded subsets, glyph advances and text matrices.
- Link displayed text spans and images to their exact source operators; expose uncertainty/unsupported files explicitly.
- Build a writer that preserves untouched objects and document structure. Validate exports with independent readers.

Start with generated fixture documents with known fonts and simple content streams. Do not promise arbitrary PDF text editing until a diverse regression corpus passes.

## Milestone 3 — genuine content editing

- Replace/delete source text operators, embed fallback fonts when the original subset lacks the new glyphs, preserve position and styling.
- Handle multiline edits and overflow with explicit UI behavior; avoid claiming Word-like global reflow.
- Replace/move/resize images and isolate shared objects so changing one page does not unintentionally change another.
- Preserve bookmarks, links, annotations, forms and accessibility tags where supported.
- Add rendered before/after comparison, original-text extraction assertions and reopen checks in independent readers.

## Milestone 4 — secure and advanced operations

- Real redaction: remove affected source content and image regions; separately sanitize metadata, attachments, hidden content and previous revisions. Verify extraction cannot recover the removed information.
- Preserve encryption, permissions and authentication across editing/export; never silently decrypt user files.
- Form checkbox/radio/choice controls, shared field names, appearances, multiline/comb fields and consistent AcroForm field-tree updates.
- Searchable OCR PDFs, multilingual controls, compression with quality preview, watermark/page numbering, crop and batch operations.
- Certificate signatures/verification as a separate module; signed-document changes must explicitly communicate signature impact.

## Corpus and release gates

Use original and scanner PDFs with English/Cyrillic/CJK/RTL, embedded subset/CID fonts, rotated/nonzero-origin pages, nested XObjects, unusual crop boxes, forms, password protection, signatures and large page counts. Use only fixtures we own or may redistribute.

Every advertised operation must pass: correct appearance, preserved logical content, save/reopen, undo/redo, original preservation and graceful unsupported-file handling. Existing-text replacement must prove the old text was removed, not visually covered.
