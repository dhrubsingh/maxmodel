# Images and documents

Drop in screenshots, photos, and PDFs and ask about them. Everything is read on the Mac; nothing is uploaded.

The code is in `Sources/HearthCore/Attachments.swift` (processing and what the model receives), `Sources/Hearth/AttachmentViews.swift` (interface), and the attachment parts of `AppStore.swift` and `Engine.swift`.

## Attaching

- **Drag** files anywhere onto the chat, **paste** with ⌘V, or use the **paperclip**. Up to 10 images or PDFs per message.
- Each file appears as a **chip** immediately and is read off the main thread. A message can be sent with attachments and no text.
- Unsent attachments are saved with the conversation's draft, like draft text, and survive a restart.
- **Edit question** brings the original attachments back.

## How files are read

| Kind | What happens |
| --- | --- |
| Images (PNG, JPEG, HEIC, and other formats macOS reads) | Downscaled to 1,600 px on the long side with rotation applied, transparency flattened onto white, saved as JPEG with a small thumbnail. Text is recognized on device with Apple's Vision framework. |
| PDFs | The text layer is extracted page by page. Pages without one (scans) are rendered and read with text recognition, up to 40 pages. Extraction stops at 600,000 characters. Password-protected PDFs are refused with instructions. |

Measured on an M4: a Retina screenshot is ready in about 0.4 s (0.9 s for the first one after launch), a 24-megapixel photo in about 1.7 s, and the interface never paused more than 40 ms while reading.

## Models that can see

22 catalog configurations can look at images: every Qwen3.5 size, Gemma 3 (4B and up), Gemma 4, Ministral 3, and Mistral Small 3.2. The model switcher marks them **Sees images**.

- **Image support is an add-on file**: the publisher's F16 image encoder (`mmproj-F16.gguf`), pinned to the same repository revision as the weights and hash-checked the same way. It's 672 MB for Qwen3.5 4B and about 0.9 GB for most others.
- **It downloads automatically after its model**, so chat can start sooner, or on demand from the composer or the model details. The download lock blocks it like any other download.
- **It loads only when it fits** the Mac's memory budget alongside the model. If loading with it fails, MaxModel retries without it and says images will be read as text this time.
- **Each image is capped at 512 tokens.** Image tokens take about four times as long to read as text, so up to 3,000 characters of recognized text accompany each image to carry fine print the downsampled image can't. Precise object locations would need 1,024 tokens; nothing in MaxModel asks for them.
- **Follow-up questions reuse the encoded image** instead of processing it again.
- While the model looks, the reply shows **Looking at your image…**.

## Models that can't see

- They receive the recognized text, labelled as text from an image with layout, colors, and pictures unavailable.
- The composer says so **before** sending ("can't see images, so it will read the text in them") and offers one click to switch to an installed model that can see.
- An image with no readable text tells the model to say it can't see the image rather than guess.

## Long documents

Documents are cut at a page boundary to fit the model's conversation window: about 15–20 pages at 16K tokens. The chip says how much fits ("first 14 of 40 pages fit"), and the model is told the rest was left out so it can say when an answer may be in later pages. The cut is fixed for a given configuration, so earlier turns render identically and the engine's prompt cache stays valid.

## What the model is told

The assistant instructions name the running model and tell it to treat shared content as real and current. Without that, Qwen3.5 4B called a real screenshot of itself a "mockup," because Qwen3.5 postdates its own training data.

## Where files go

Attachments are stored in `~/Library/Application Support/MaxModel/Attachments/`, named by attachment ID, with owner-only permissions. Original files are not copied; only the downscaled image, thumbnail, and extracted text are kept. Removing a chip, or deleting the last conversation that uses an attachment, deletes its files. Exports list attachment names.

## Measured with real models

On the development M4 (16 GB) with Qwen3.5 4B, thinking off unless noted, under varying system load:

| Case | First answer |
| --- | ---: |
| Question about an image (invoice with a colored shape) | 4.6–8.9 s |
| Follow-up about the same image | 0.5–0.8 s |
| Real Retina screenshot of the app | about 6–10 s |
| PDF question | 1.0–2.1 s |
| Same image, text-only Qwen3 4B reading recognized text | 1.1–1.8 s |
| Question about an image with thinking on | about 12.7 s |

Halving the image cap from 1,024 to 512 tokens roughly halved the wait on a busy machine (10.7–14.8 s down to 6.8–7.7 s) with no loss of accuracy in testing.

## Limits

- Image understanding is runtime-tested with Qwen3.5 4B. The other 21 encoders are pinned and hash-checked but not yet run through the engine; reports from contributors are welcome.
- Text recognition reads up to 40 scanned pages per PDF.
- Timings come from one M4 under varying load.
