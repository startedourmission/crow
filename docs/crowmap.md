# Crowmap

Crowmap opens in an independent bottom panel with its own tabs, above the workspace level. Its file list occupies a separate, resizable lower third of the left sidebar; the upper workspace/file pane stays unchanged. The activity-bar icon above Settings reveals this sidebar and the bottom map panel. Use the panel’s close button to hide the map view. The panel’s file-list button reveals the sidebar; clicking a file opens a panel tab. The sidebar + creates a separate map file or opens an existing folder of notes as a Crowmap. A folder already in `~/.crow/crowmap` gets a `.crowmap` display cache if it lacks one; a folder elsewhere is linked into the library so its Markdown stays in place. Removing a linked map from Crow leaves the original folder and notes. Right-click a workspace or Crowmap tab to pin or unpin it. Pinned tabs stay before ordinary tabs; their state survives session restoration, and Close Other Tabs preserves workspace pins. Open maps, pinned tabs, the selected tab, panel height, and unsaved note drafts are saved separately from workspaces. Switching workspaces or hiding the panel keeps each map mounted, preserving its view and embedded editor; hidden maps pause their animation. Clean map tabs from older sessions migrate into this panel. The upper workspace retains its own Back and Forward navigation.

Right-click a map in the sidebar to rename, duplicate, or delete it. Rename updates the display name and `.crowmap` filename while retaining its directory, so agent working directories and history remain valid. Duplicate makes an automatically numbered map with independent notes and resources, excluding agent sessions. Delete asks for confirmation and moves the map’s dedicated folder to `~/.crow/crowmap-deleted`; shared folders retain their other files. Unsaved edits and running map agents must be resolved before deletion.

Both **Create first project** and the map’s always-visible top-right **+** immediately add a sample timeline to the current map: a start note and four milestone notes, dated a week apart. Each new project starts below the existing projects. No setup form is required.

Each map has a directory under `~/.crow/crowmap`, for example `test/test.crowmap` with that map's Markdown notes beside it. Notes remain flat within each map; external resources stay linked. Start notes, milestones, revision notes, and work notes are all `.md` files with dated frontmatter. On iOS this directory is inside the app's home container. The start filename is the project name (`Website.md`). Milestones use a project prefix (`Website-Research.md`), and numeric suffixes avoid remaining collisions. The editable filename above the properties renames the actual note; Crowmap wiki references and cached node identities follow the rename.

## Connect notes with links

The start note contains a list of Obsidian-style links for all its milestones, including disconnected ones:

```yaml
---
title: Website
date: 2026-09-18
priority: 1
kind: start
milestones:
  - "[[Website-Research]]"
  - "[[Website-Prototype]]"
  - "[[Website-Release]]"
previous: []
next:
  - "[[Website-Research]]"
---
```

Milestones link their neighbors:

```yaml
---
title: Prototype
date: 2026-10-02
priority: 1
kind: milestone
project: "[[Website]]"
previous:
  - "[[Website-Research]]"
next:
  - "[[Website-Release]]"
---
```

Connections come from `previous` and `next`. Either endpoint can describe a connection; when removing a connection, remove both references if both are present. **Refresh map** rereads the links, including newly linked files. Filename links, unique titles, and aliases are supported. Missing or ambiguous links and invalid dates show errors instead of silently changing the plan. The `.crowmap` graph is a display cache: editing its IDs or graph JSON is unnecessary. An empty or stale cache discovers every `kind: start` Markdown note in the map folder, follows its milestone links, and includes dated work notes. Crow saves the rebuilt display cache without rewriting those Markdown files. Use Refresh Crowmap files in the sidebar for maps created outside the app, and Refresh map in the view for externally edited notes. Existing maps convert their old properties to links when opened, preserving note bodies and custom properties.

Work notes attach to a dated segment with links:

```yaml
---
title: Implementation notes
date: 2026-09-28
between:
  - "[[Website-Research]]"
  - "[[Website-Prototype]]"
---
```

For a direct milestone memo, use `milestone: "[[Website-Prototype]]"` instead of `between`.

## Timeline and editing

Time runs horizontally; priority runs from the top down. Connected work notes are visible by default. Click a node to open its Markdown document in an embedded editor at the clicked location. Properties, headings, lists, tables, undo, and Korean input use the same editor components as document tabs. Changes save automatically; errors keep the draft available. The top-right expand icon opens the actual Markdown file in a regular tab.

Click an edge for its actions in a popup at that location. Attached notes stay visible on the graph rather than being repeated as a list in the popup. **Add work note** creates a dated Markdown file and opens it immediately for editing, without a separate creation form. Click the background, the close button, or Escape to dismiss the popup after saving.

A Markdown file is one node. A body link such as `[[Implementation notes]]` draws a weak connection to that existing node; it never creates another copy. A dated note first reached through a body link is added once. External URLs remain separate terminal nodes for each occurrence, as links to outside resources do not merge notes.

**Add milestone** immediately creates a new Markdown milestone and an additional main branch, preserving every existing connection. Every milestone with an incoming or outgoing timeline edge is main, including multiple milestones on the same date. Colliding milestones stack vertically with their own labels and curved edges. Drag a milestone’s small connection point to another milestone to connect them; drag the node body to move its date or priority. Dates cannot cross connected milestones or leave attached work outside its segment. Use **Disconnect milestones** in a segment popup to remove that edge from both notes' `previous`/`next` properties. Only a milestone with no remaining edges is faded; its Markdown file stays in the start note's `milestones` list. Work on a removed edge becomes a memo on its source milestone. Legacy `inactive_next`, `replaces`, and cached superseded states no longer deactivate connected milestones.

Date columns have a fixed width. Map controls choose the scale: Day, Week, Month, or Year. Day labels use MM/DD; week labels mark each week start; month labels use the month name; year labels use the year. A single year label stays at the top left for day, week, and month scales and follows the visible range when scrolling horizontally. During node moves, the target date column and milestone priority lane are highlighted. Timeline bends use curves. Work nodes float gently around their dated attachment, with live connecting lines; reduced-motion settings disable the animation. Node sizes reflect their connections, and the controls popup adjusts line thickness.

Drag an empty region to select work notes, or use Command-click to toggle individual notes. Start notes, milestones and timeline edges are excluded from box selection. Right-click the selected group for bulk deletion or **Run Codex / Claude / Grok with N notes**. Local agent sessions live at `<map folder>/.sessions/<id>/`; `notes/` contains symlinks to the chosen original Markdown files. Agents receive structural guidance from the map’s `AGENTS.md` and a session-specific selection list. Agent tabs carry explicit Crowmap ownership and appear beneath that map in the Crowmap sidebar, rather than beneath the containing workspace. The agent history panel aggregates the map’s session directories; opening a saved conversation resumes its original selection directory. New unsaved sessions appear immediately, and older map agents are recognized by their session path. Existing user-written instructions are preserved. Remote device notes remain read-only and cannot be selected for a local agent session.

## Other devices

Connect an SSH account in Workspaces, click a segment, and choose **Attach device notes**. Crow reads dated Markdown directly from that account's `~/.crow/crowmap`. Remote notes retain their source and are cached for disconnected viewing. Reattaching the same device's file does not create another node.

**Refresh map** updates attached remote notes and discovers new notes whose `between` or `milestone` links match a segment or milestone already attached through that device. Old ID-based remote attachments remain supported. Reads are limited to 300 flat Markdown files, 128 KB per note, and 10 MB per refresh. This is explicit refresh over SSH, not automatic synchronization.

Saves check changed files and open editor drafts before writing. Disconnecting a timeline edge preserves its Markdown notes.

The adjacent controls button toggles a popup containing search, disconnected milestone visibility, zoom, fit, and refresh. Zoom buttons keep the current viewport center anchored; Cmd/Ctrl-wheel zoom keeps the point under the pointer anchored, including over nodes and date labels. Fit resets the view to the timeline origin. Work-note context menus create linked notes or delete the selected note; deleted Markdown is retained outside the flat note root in `~/.crow/crowmap-deleted`.

## Copying and ordering

Every Markdown node has **Copy** and **Duplicate** in its context menu. Copy places actual Markdown file URLs on the system clipboard. Duplicate immediately creates numbered files in the current map. A work note or milestone copies only its own file; a start note includes all its project's milestone files, including disconnected milestones, but never attached work notes or device nodes. Timeline duplicates remap internal links to the new filenames. Existing body links remain references, not recursive copies. Remote work notes duplicate as local snapshots.

Drag one milestone onto another on the same date to swap their vertical display order. This lives in the `.crowmap` view state and does not edit Markdown dates, priorities, or connections. Dragging to a different project rank sets one priority for all milestones at that project/date, avoiding contradictory simultaneous priorities. Hold **Command** during that priority drag to apply the new priority to all later milestones in the same project as well. Earlier milestones and other projects keep their stored properties.

Right-click a start note and choose **Delete timeline** to remove the whole timeline, including its milestones and attached work notes. A modal lists the affected counts; **Cancel** keeps everything and **Enter** confirms deletion. Local files go to Crowmap's deleted-notes folder; remote references disappear from this map but their original files are untouched. Other timelines and the map file remain. Changes in open editors or on disk block deletion until reconciled.

After **+** adds a sample timeline, the viewport scrolls to its start node and focuses it for keyboard navigation.

Opening a new agent while a Crowmap tab is focused starts it directly in that map’s folder and groups it under that map in the sidebar and conversation history. Explicit session directories (such as selected-note sessions) keep their specified locations.
