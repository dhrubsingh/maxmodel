# Using MaxModel

A tour of the app, from first launch to managing models. The sidebar has three places: **Chat**, **Models**, and **This Mac**.

- [Installing](#installing)
- [First launch](#first-launch)
- [Chatting](#chatting)
- [Choosing and comparing models](#choosing-and-comparing-models)
- [Why this one? Settings, checks, and tuning](#why-this-one-settings-checks-and-tuning)
- [Managing storage and memory](#managing-storage-and-memory)
- [This Mac](#this-mac)
- [Updates](#updates)
- [Moving from Hearth, and uninstalling](#moving-from-hearth-and-uninstalling)

## Installing

1. Download from [dhrubsingh.github.io/maxmodel](https://dhrubsingh.github.io/maxmodel/). The page offers the right build for Apple Silicon or Intel.
2. Unzip and drag **MaxModel** to Applications.
3. **If macOS says it can't verify the developer:** early builds aren't notarized yet. Open MaxModel once, then go to **System Settings → Privacy & Security** and click **Open Anyway**. You only do this once; updates install without it.

Requires macOS 14 or later. Apple Silicon is tested on an M4 with 16 GB; Intel builds are packaged and verified but not yet tested on Intel hardware. You need disk space for the model you choose (MaxModel leaves room for macOS and your other apps), and internet only to download models. Once a model is installed, chat works offline.

## First launch

**Models → Your assistant** leads with one recommendation for your Mac: the most capable open model that fits its memory and answers at a comfortable pace. [How MaxModel picks a model](recommendations.md) explains the reasoning.

- **Get it** downloads, verifies, installs, and loads the model, then **Start chatting** opens a chat. No benchmark runs first.
- Models with custom license terms (such as Llama or Gemma) ask you to review and accept them before downloading.
- **Why this one?** shows the evidence behind the pick; **Details** describes the model.
- If other apps are holding memory right now, MaxModel says so separately. It never changes the recommendation itself.
- **Compare other models** opens everything that fits, with benchmarks and side-by-side answers.

## Chatting

**Writing**

- Starter cards fill an editable draft and never overwrite one you've started.
- Each conversation keeps its own draft, and the last open conversation comes back after a restart.
- You can write the next question while a reply is still streaming.

**Replies**

- Replies stream in and render as formatted text: headings, lists, task lists, quotes, tables, inline code, and code blocks with preserved whitespace, horizontal scrolling, and a copy button.
- Models that think first show their reasoning in a separate, collapsible section. The thinking budget always leaves room for the final answer.
- Scrolling up pauses auto-scroll; **Latest** brings you back.

**Fixing an answer**

- **Retry / Try again** keeps earlier attempts in a disclosure without duplicating the question or sending archived answers back to the model.
- **Continue** extends a reply and keeps any unsent draft.
- **Edit question** starts a revised conversation and keeps the original, including its attachments.
- If something fails, the error stays with that reply, with a button to recover.

**Moving around**

- Switch conversations while a reply is running; a shortcut takes you back to it.
- **Export conversation…** and **Delete conversation…** are in the menu at the top of a chat. Export is also in the **Assistant** menu, and you can delete from a conversation's context menu in the sidebar.

| Shortcut | Action |
| --- | --- |
| ⌘N | New conversation |
| ⇧⌘M | Explore models |
| ⌘. | Stop the response |
| ⌘V | Paste an image or file into the composer |

**Images and documents**

- Drag, paste (⌘V), or attach screenshots, photos, and PDFs. See [Images and documents](images-and-documents.md).

**What the model knows**

- The chat footer shows the model's **knowledge cutoff**. Models don't know about events after it.
- **About this model** shows the publisher source, what the model is good at, its limits, and image support.

**Long conversations**

- When a chat outgrows the model's window, the oldest complete turns are left out and a notice says how many.
- A single message too long for the window is refused with an explanation, never silently cut.
- **Longer chats** keeps up to 64K tokens in view; see [below](#why-this-one-settings-checks-and-tuning).

## Choosing and comparing models

- **Switch models** from the model pill in chat. Models that can see images are marked **Sees images**.
- **Models → Explore models** is the full catalog. Related sizes and precisions share one card. Filter by fit, family, use (everyday, coding, reasoning), or license, and sort by suggested order, size, or name. See [Models and licenses](models-and-licenses.md).
- **Compare side by side:** mark up to three models in the catalog. The comparison has three views:
  - **At a glance:** what each is good for, its tradeoff, knowledge cutoff, and license, then fit, memory, download size, and speed on this Mac.
  - **Example answers:** recorded answers to sample tasks, viewable before you download. Qwen3 4B, Qwen3 1.7B, and Gemma 4 E2B have them, with exact weight hashes, dates, and reference hardware. They're examples, not a leaderboard.
  - **Try your question:** runs your question through installed models one at a time. **Continue this chat** turns the answer you like into a normal conversation.

## Why this one? Settings, checks, and tuning

**Why this one?** (on the home screen, or **Why this one, benchmarks & tuning…** in a model's details) explains a recommendation with published benchmarks, memory fit, and expected speed.

**Tune the recommendation**

- **Optimize for:** **Best answers** (default), **Balanced**, or **Light & quick**.
- **Look at another model:** see how any model compares on this Mac.

**Advanced · memory, local checks & tuning**

- **Conversation memory:** the everyday window, or **Longer chats** with up to 64K tokens.
- **Allow compact conversation cache when it helps:** the Q8 cache precision override.
- **Run local check:** measures speed and runs six basic answer checks on synthetic prompts.
- **Check longer memory on this Mac:** a retrieval test with facts hidden in a long input.
- **Tune for this Mac:** compares execution settings and keeps any that are reliably faster. **See what was tried** lists every trial, and **Restore automatic settings** undoes a tune.

None of these read your chats. Details are in [How MaxModel picks a model](recommendations.md#local-checks) and [Memory and performance](memory-and-performance.md).

The app also keeps each model's latest timing and memory observation from your real conversations, separately from controlled tests. These observations never rank answer quality or retune a model on their own.

## Managing storage and memory

**Models → Manage storage** lists every installed model and paused download, whatever the catalog filters are set to. The home screen shows the same total ("2 downloaded · 6.1 GB").

- **Downloads:** show progress and an ETA, pause and resume (even across restarts), and check free space first.
- **Removing a model:** frees its disk space, including image support, and keeps your chats.
- **Release model memory:** unloads the model but keeps it installed. MaxModel does this on its own after 15 minutes idle, or under memory pressure when nothing is running. The next message reloads the model.
- **Local checks:** run one from here for any installed model. Results record the date, model digest, engine version, context length, chip, token count, and process memory (an observation, not total GPU allocation).

## This Mac

**This Mac** shows the chip, memory, memory speed, storage, and current conditions: memory pressure, temperature state, and Low Power Mode.

- **Refresh hardware** rescans on demand. MaxModel also rescans when you return to the app and before loading a model.
- **Download lock** blocks all new downloads; installed models keep working.
- **Show technical details** adds precision, context window, estimated speed, and benchmark figures throughout the app.
- **Show files** opens the data folder in Finder.

## Updates

On the second launch, MaxModel asks once whether to check for updates automatically. If you say no, it never checks on its own. **MaxModel → Check for Updates…** checks any time. Every update is signed and verified before it installs.

## Moving from Hearth, and uninstalling

- MaxModel was called **Hearth** before 0.9. On first launch, `~/Library/Application Support/Hearth` is moved in place to `~/Library/Application Support/MaxModel`, models and chats included. If the move fails, the old folder is left untouched.
- **To uninstall,** delete the app and the `~/Library/Application Support/MaxModel` folder, which holds your models and chats. See [Privacy and security](privacy-and-security.md#whats-stored-and-where).
