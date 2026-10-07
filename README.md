# PDF Editor for iOS

Native iPhone/iPad PDF editor with our own `PDFEditorCore`, built on Apple's PDFKit, Core Graphics and Vision. No third-party PDF SDK, backend, account, or subscription is required by the current implementation.

## Run

1. Open `PDFEditor.xcodeproj` in Xcode 16 or later.
2. Select **PDFEditor**, choose your development team in Signing & Capabilities, and run on an iPhone/iPad or simulator. Deployment target: iOS 17.
3. Tap **Try the editor** for a three-page practice PDF including a text form field.

The default bundle ID is `com.sultonovmuzafar.pdfeditor`. Update it in `Scripts/generate_project.py` if needed, then regenerate the project.

```bash
python3 Scripts/generate_project.py
bash Scripts/validate.sh
bash Scripts/validate.sh --ios
```

The project generator uses Python's standard library. `--ios` requires Xcode and an installed iOS simulator runtime. GitHub Actions runs portable Swift tests and hosted iOS PDF integration tests.

## Implemented

- Local library: import PDF files, rename, duplicate, favorites, recoverable trash, original preservation.
- PDF viewing: zoom, scrolling, selectable text, search results, page thumbnails.
- Standard PDF annotations: free-text boxes with font/color/position/size, ink, handwritten signatures, rectangles, highlight/underline/strikeout, annotation eraser.
- Text annotation editing: tap an existing free-text box in Read mode.
- Text form fields: tracked edits, undo and saved values. Other widget types are not yet supported.
- Pages: rotate, duplicate, delete, drag to reorder, insert blank A4, append PDF or photo pages, extract ranges to a new library document.
- Camera scanning and photo-to-PDF creation. Camera scanning requires a supported physical device.
- On-device OCR of the current page, selectable recognition output and TXT export.
- Original text editing: **Edit text** → tap a supported horizontal source text object → replace or delete its text, change size/color, save and Undo/Redo. Unicode replacement fonts are embedded using CoreText.
- Source inspection: extracted text lines/bounds and low-level counts of source PDF text/XObject drawing commands.
- Session Undo/Redo, debounced autosave, atomic file replacement, PDF export, AirPrint and original export.
- English/Russian UI and error messages; adaptive iPhone/iPad layout, system appearance.

## Honest engine boundaries

Original-text replacement is now implemented for a conservative subset: classic cross-reference tables; plain/Flate page content; simple WinAnsi fonts or fonts with supported ToUnicode CMaps; horizontal single-line BT/ET objects. The writer removes the selected source text operands and inserts ordinary selectable text with imported font resources, then rewrites reachable objects. It does not use a covering rectangle. Shared page contents/resources are isolated before editing. Replacement text can be edited again.

The UI shows the replacement font, which may differ from the original font. New text must fit on one line within the crop box; overlap with other supported text blocks is rejected. Paragraph reflow, original font-subset extension, nested Form XObject text, inline images, tagged/ActualText text, clipping, unusual text states, object/xref streams and incremental xref chains are unsupported. Some files become compatible after PDFKit serialization; unsupported files fail explicitly. This is not secure redaction: font programs, metadata, attachments and other copies of text are not sanitized. Existing images cannot yet be replaced. Signed/XFA PDFs are rejected by the content engine.

Encrypted PDFs can be unlocked for viewing and exported unchanged; editing them is disabled until the engine can preserve encryption and permission settings reliably. Handwritten signatures are ink annotations, not certificate-based signatures. OCR currently exports text; it does not generate a searchable PDF or reconstruct editable scan layout.

Original imported files remain outside the editing path. The app keeps both `original.pdf` and `working.pdf` in a private per-document directory. Autosave modifies only `working.pdf`; undo history is in memory and bounded to 12 snapshots / approximately 64 MiB per stack (one oversized snapshot can be retained). Undo history does not survive restarting the app. Very large files need further performance work before release.

## Structure

| Path | Responsibility |
| --- | --- |
| `Sources/PDFEditorCore` | Native engine, transactional edits, page operations, annotations, history, source analysis, object parser/writer and source text replacement |
| `PDFEditor/Library` | Library storage and document management |
| `PDFEditor/Editor` | Viewer, tool interactions, annotation/form sheets, signatures and page organizer |
| `PDFEditor/Services` | Camera, share sheet, demo document and on-device OCR |
| `Tests/PDFEditorCoreTests` | Portable range/name/history, lexer, CMap and source rewrite tests |
| `Tests/PDFEditorAppTests` | iOS PDF persistence, undo, forms, merge/extract, encryption and original preservation tests |
| `Docs/ENGINE_ROADMAP.md` | Next stages of the engine |

This is an initial working implementation, not a claim of full Acrobat-level compatibility. Run the iOS test suite and device checklist before shipping.
