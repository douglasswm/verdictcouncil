# UML 2.5 Diagrams — Rendering and Re-embedding

This folder holds the canonical PlantUML sources for the four UML 2.5 diagrams referenced from the group report:

| File | UML 2.5 diagram type | Embedded as |
|---|---|---|
| `01_high_level_workflow.puml` | Activity Diagram | Figure 1 (§2 High-Level Workflow) |
| `02_logical_architecture.puml` | Component Diagram | Figure 2 (§3.1 Logical Architecture) |
| `03_physical_architecture.puml` | Deployment Diagram | Figure 3 (§3.2 Physical Architecture) |
| `04_cicd_pipeline.puml` | Activity Diagram | Figure 4 (§7 CI/CD Pipeline) |

The `.puml` sources are the authoritative artefact. The `*.png` files in this folder are renders that get embedded into `VerdictCouncil_Group_Report.docx`.

> The PNGs that currently ship with the report were produced by Graphviz (the build sandbox couldn't run PlantUML). Re-render with PlantUML for canonical UML 2.5 output that includes lollipop / socket interfaces, `«deploy»` arrows, swimlanes, time-event markers, and the legend boxes — all of which Graphviz strips.

---

## 1. Render with PlantUML

### Install PlantUML once

PlantUML needs Java 8+ and Graphviz. On macOS:

```bash
brew install plantuml          # also installs graphviz as a dependency
```

Or download `plantuml.jar` directly:

```bash
curl -L -o plantuml.jar https://github.com/plantuml/plantuml/releases/latest/download/plantuml.jar
```

### Render the four diagrams

From this folder:

```bash
# If you installed via brew
plantuml -tpng -o . *.puml

# Or with the jar
java -jar plantuml.jar -tpng -o . *.puml
```

This overwrites `01_high_level_workflow.png` … `04_cicd_pipeline.png` with canonical UML 2.5 renders.

### Verify

Open the four PNGs and confirm:

- **`01_high_level_workflow.png`** — three swimlanes (Judge / FastAPI / Worker), four gates as decision diamonds, fork/join over the four research subagents, two terminal types (`stop` activity-final ◉ and `end` flow-final ⊗ for halts), object-flow notes for `CaseState.intake / research_output / synthesis / audit`, and a legend.
- **`02_logical_architecture.png`** — three tier packages, components rendered as rectangles with the two-tab UML icon, lollipop (`─○`) provided interfaces and socket (`─⊃`) required interfaces, assembly connectors between SPA and api-service, and dashed `<<delegate>>` / `<<trace>>` dependencies inside the application tier.
- **`03_physical_architecture.png`** — one `«artifact»` (`verdictcouncil:latest`) with three `«deploy»` dashed arrows to the three execution environments (api-service / arq-worker / watchdog). External SaaS rendered as `«executionEnvironment»` rather than `«device»`. Communication paths stereotyped with their wire protocol.
- **`04_cicd_pipeline.png`** — five swimlanes (Developer / Quality gates / AI-specific gates / Promotion / Operations), distinct activity-final and flow-final nodes for success vs. failure, and an independent activity for the weekly cron-triggered red-team with an accept-time-event marker.

---

## 2. Re-embed the new PNGs into the report

Run the swap script from the repository root:

```bash
cd /path/to/VER
bash diagrams/swap_diagrams.sh
```

The script:

1. Unzips `VerdictCouncil_Group_Report.docx` to a temp folder.
2. Replaces `word/media/image3.png` … `image6.png` with the four newly-rendered PNGs.
3. Re-zips the folder back to `VerdictCouncil_Group_Report.docx`.

The image relationships, figure captions, and document layout are already wired up — only the picture bytes change. **No re-build of the report is needed.**

---

## 3. If you change a `.puml` source

Same workflow:

```bash
plantuml -tpng -o . *.puml
bash swap_diagrams.sh
```

The captions in the docx are static text; if a diagram's purpose or figure number changes, edit `build_report.js` and re-run the full rebuild instead.

---

## 4. Notes on UML 2.5 fidelity

The four `.puml` files were authored to clauses 11 (Components), 15 (Activities) and 19 (Deployments) of the OMG UML 2.5.1 specification. Specifically:

- **Activities (clause 15):** initial node, action node, decision/merge, fork/join, partitions, activity-final vs. flow-final, accept-time-event (for cron), object flow.
- **Components (clause 11):** `«component»` classifier, ports, provided interface (lollipop), required interface (socket), assembly connector, dependency with stereotype.
- **Deployments (clause 19):** `«device»`, `«executionEnvironment»`, `«artifact»`, `«deploy»` dashed dependency, communication path with protocol stereotype.

Aspect-ratio and font choices are PlantUML defaults plus an EB Garamond override to match the report body. Skin parameters use the report's crimson accent.
