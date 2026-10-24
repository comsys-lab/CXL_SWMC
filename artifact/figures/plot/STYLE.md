# Lab paper figure style

Reference: hpca2027-paper249.pdf (De Stijl, HPCA 2027 submission), Fig. 8 (latency vs request rate),
Fig. 10 (grouped bars), Fig. 11 (bars and stacked breakdown); user rules of 2026-10-18. Implemented in
workspaces/figs-h1h2/style.py; every new figure should import it rather than copy settings.

## Size and fonts
- Draw at print size: double column 7.0 in wide, single column 3.3-3.4 in. A row of panels is 1.35-1.6 in tall
  (axes only), so fonts are real points.
- One bold sans font for everything inside the plot: Liberation Sans Bold (Arial metrics), 8 pt for tick labels,
  axis labels and legend (7 pt for crowded categorical tick labels). Exponents (10^n) in the same font.
- Scenario name under each panel in the same bold sans font, 9 pt, without "(a)" (user 2026-10-18), e.g.
  "Search-heavy (95:5)". No titles inside a figure.

## Axes
- Black frame on all four sides (1.3 pt); NO tick marks on either axis (labels only); light
  gray horizontal grid at every y tick (#d9d9d9, 0.8 pt), behind the data.
- Tick labels are integers. Put a scale factor into the axis label when values exceed 999, e.g.
  "Embedding-row update rate (x10^3 rows/s)"; no "K"/"k" suffix. Use a log axis with 10^n labels when values span
  more than two decades (e.g. faults per query, invalidated bytes per modified byte).
- Axis label text: plain words with the unit in parentheses ("p99 latency (ms)", "Searches per second").
  Two-line y labels are fine ("Normalized time\nper search"). In a row of panels only the leftmost panel carries the
  y label; every panel has its own x label (Fig. 8).

## Series and colours (grayscale only)
- Order series left to right (legend order = bar order); the leftmost series is the lightest, the rightmost black,
  the ones in between evenly spaced grays. Lines: 3 series #BBBBBB, #777777, #000000; 2 series #BBBBBB, #000000.
  Bars: the lightest series may be white with a black edge (Fig. 10/11).
- The same system keeps the same gray in every figure with the same system set (H1: All-HWcc #BBBBBB, Megalon
  #777777, Popcorn black; H2: All-HWcc #BBBBBB, Popcorn black).
- Every point is a small filled circle (3.3 pt) on a 1.8 pt line of the same gray; no other marker shapes, no hollow
  markers, no special knee markers.

## Latency vs throughput (Fig. 8)
- One panel per scenario in one double-column row; one shared legend centred above the row, no frame.
- Draw every pooled measurement point, including those past the SLO (curves run past the SLO line and may leave the
  top of the axis; say so in the caption if points are clipped).
- y = tail latency normalized to All-HWcc's tail latency at its lowest request rate (per scenario); y name
  "Normalized 99<sup>th</sup> percentile latency" (superscript "th"; never "p99"); the SLO is normalized by the same
  base. The "SLO" label sits just above the line at the first free spot (right, left, centre) that no curve crosses.
- The y-axis zero is written "0" (never "0.0"), also on decimal axes.
- SLO: black dashed horizontal line (1.6 pt) with the word "SLO" just above its right end. y-axis top: an integer
  with the SLO line at 75-85 % of the height (closest to 80 %) and an integer tick step that divides it into 3-6
  intervals; for small normalized SLOs (< 5) 0.5 steps are allowed; if nothing fits, the band widens to 73-87 %
  (style.slo_axis). Per-figure choices by the user: H1 Balanced ends at 12 (SLO 87 %); H2 uses 0.5 steps in all
  panels.
- Points: steps of one SLO search at the same offered rate (within 3 %) are one point: pool the per-request
  latencies and recompute the percentile; leave out steps the load generator aborted early (partial windows).
  Join points in offered-rate order.
- Pooling never mixes steps at or below the confirmed max-under-SLO rate with steps above it.
- Shape filter (user 2026-10-18: drop what hides the curve shape, but always show the SLO crossing; pool.shape_filter):
  up to the max-under-SLO rate, draw the longest chain of points whose throughput rises and whose latency never
  falls below 0.95 x the previous drawn point; above it, draw every point past the SLO in offered-rate order, even
  where the throughput bends back (user 2026-10-18). Dropped points stay in the CSV
  (drawn = 0); report how many were dropped.

## Bars and breakdowns (Fig. 10, 11)
- Bars have a 1.1 pt black edge. Grouped bars: groups on the x axis, series side by side, legend above the plot.
- Stacked breakdown: components from black at the bottom to white at the top (Fig. 11b); two components:
  Query processing (update panels: Update processing) black (bottom), Coherence management white (top). The legend sits to the RIGHT of the panels and lists the
  components top to bottom in stack order ("Coherence management", then "Query processing").
- Breakdown bars are normalized to the baseline (All-HWcc) of the same scenario and load; system names (7 pt) under
  the bars; one panel per scenario; the scenario is the panel's x-axis name in the same bold sans font
  ("Search-heavy (95:5)", no "(a)").
- Axis names (x and y) 9 pt, larger than the tick labels. y name e.g. "Normalized search latency" (vector DB search), "Normalized query latency" (RecSys).
- Normalized y ticks (exception to the integer rule, user 2026-10-18): top <= 1.2 -> 0 to 1.2 by 0.2; <= 2.5 ->
  0 to 2.5 by 0.5; <= 3 -> 0 to 3 by 0.5; larger -> integers. A gray grid line at every tick.

## Files
- Save PDF (fonttype 42, text stays text) and PNG (300 dpi) with tight bounding boxes; write the numbers behind each
  figure to a CSV next to it and list figure, data source and numbers in index.md.
