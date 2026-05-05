#!/usr/bin/env bash
# Replace the embedded UML 2.5 diagrams in VerdictCouncil_Group_Report.docx
# with the freshly-rendered PNGs from this folder. No report rebuild needed —
# only the picture bytes inside the .docx ZIP are swapped.
#
# Usage:    bash diagrams/swap_diagrams.sh
# From:     repository root (VER/)
#
# Pre-conditions:
#   - The four PNGs exist in this folder:
#       01_high_level_workflow.png
#       02_logical_architecture.png
#       03_physical_architecture.png
#       04_cicd_pipeline.png
#   - VerdictCouncil_Group_Report.docx already has image3.png … image6.png
#     embedded at word/media/ (it does — built by the project pipeline).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIAG="$ROOT/diagrams"
DOCX="$ROOT/VerdictCouncil_Group_Report.docx"
WORK="$(mktemp -d -t vc_swap.XXXXXX)"

if [ ! -f "$DOCX" ]; then
  echo "ERROR: $DOCX not found. Run from the repository root." >&2
  exit 1
fi

# 1. Verify the four PNGs exist.
for f in 01_high_level_workflow.png 02_logical_architecture.png \
         03_physical_architecture.png 04_cicd_pipeline.png; do
  if [ ! -f "$DIAG/$f" ]; then
    echo "ERROR: $DIAG/$f not found. Render with PlantUML first:" >&2
    echo "        cd $DIAG && plantuml -tpng -o . *.puml" >&2
    exit 1
  fi
done

echo "Unpacking $DOCX to $WORK ..."
unzip -q "$DOCX" -d "$WORK"

# 2. Swap the four embedded PNGs.
cp "$DIAG/01_high_level_workflow.png"   "$WORK/word/media/image3.png"
cp "$DIAG/02_logical_architecture.png"  "$WORK/word/media/image4.png"
cp "$DIAG/03_physical_architecture.png" "$WORK/word/media/image5.png"
cp "$DIAG/04_cicd_pipeline.png"         "$WORK/word/media/image6.png"

echo "Swapped 4 diagrams into word/media/."

# 3. Re-zip in canonical .docx order. The trick: [Content_Types].xml MUST be
#    first; the rest follows. Use store-no-recurse for the top-level then
#    add the rest in deflate.
TMP_DOCX="$(mktemp -t vc_swap_out.XXXXXX).docx"
( cd "$WORK"
  zip -X -0 -q "$TMP_DOCX" '[Content_Types].xml'
  zip -X -r -q "$TMP_DOCX" . -x '[Content_Types].xml'
)

mv "$TMP_DOCX" "$DOCX"
rm -rf "$WORK"

echo "Updated $DOCX"
echo "Open it in Word and inspect Figures 1–4."
