# Device validation

1. Build the PDFEditor scheme; run `bash Scripts/validate.sh --ios`.
2. On a real iPhone, open the practice PDF. Select text and apply highlight, underline and strikeout. Add/edit a text box, draw, erase a mark and insert a signature.
3. Fill the text field on page 2. Undo and redo; close and reopen. Export and check the field value and marks in Files/Preview or another PDF reader.
4. Rotate, duplicate and reorder pages. Append another PDF and photos; extract `1, 3-4`. Verify order and undo/redo. Attempt deleting the final page; expect rejection.
5. Import from Files/iCloud and Open In from another app. Cancel import/scan/photo selection; the library must remain usable.
6. Scan paper on a supported device. Recognize text from Page text > Recognize this page and export TXT. Test English and Russian with clear and poor scans.
7. Open a password PDF; reject a wrong password and unlock with the correct password. Editing must remain disabled; exported bytes must retain the original protection.
8. On iPad, test portrait/landscape, multitasking, keyboard, share sheet and AirPrint popover. Test dark appearance, large text and VoiceOver labels.
9. Background during editing and reopen; verify saved changes. Test low-storage save failure; previous files and the imported original must remain intact.
10. Test PDFs with 100+ pages, rotated pages, nonzero crop/media origins and existing annotations. Check memory and frame time; large-file optimization remains a release gate.

Camera, AirPrint, external Files providers and real-device performance are not covered by simulator unit tests. Do not market source-text editing, redaction, searchable OCR PDFs or certificate signatures until their engine milestones ship.
