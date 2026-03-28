# Invoice Matching System Design

## Purpose

This document is the **normative specification** for inventory-to-invoice matching.
It defines desired behavior and invariants, not a snapshot of current results.

Current operational metrics and known gaps belong in `STATUS.md`.

## Scope

The matcher maps invoice line items from JAR invoice CSV files to hardware parts discovered from host-info JSON files.

Target outcome: every invoice line ends in exactly one terminal state:

- matched to a host part automatically
- matched manually to a host
- marked standalone
- marked ignored
- unresolved (explicitly reported for review)

## Source Data (Inventory Repo)

Repository: `$WORK/inventory`

Primary source-of-truth inputs:

- `jar-invoices/*.csv` - individual invoice exports (one file per invoice)
- `online-hosts-info/*.json` - host parts snapshots

Supporting artifacts (not primary matching inputs):

- `known-hosts.csv`
- `merged-hosts.json`
- `online-hosts.json`
- `gather-info.sh`

Design decision: remove aggregate JAR CSV from this spec. Matching logic is based on individual invoice CSV files only.

## Invoice Schema

Required invoice fields (from per-invoice CSV rows):

- `purchasedbid`
- `date`
- `name`
- `mark`
- `model`
- `sn`
- `descr`
- `price`

Invoice filename convention:

- `YYYY-MM-DD INVOICE_ID.csv`

## Host Schema

Expected host-info shape:

```json
{
  "output": {
    "hostname": "machine-name",
    "parts": [
      { "name": "CPU", "mark": "Intel", "model": "Core i9-13900K", "sn": "" },
      {
        "name": "SSD",
        "mark": "",
        "model": "Samsung SSD 980 PRO 2TB",
        "sn": "S69ENF0R871366N"
      }
    ]
  }
}
```

Parser may support legacy/fallback shapes, but this nested `output` schema is canonical.

## Category Model

Category classes:

- Auto-matchable hardware: `CPU`, `MB`, `RAM`, `SSD`, `HDD`, `GPU`, `Fan`, `PSU`, `Case`
- Peripheral/manual: `Keyboard`, `Mouse`, `Monitor`, `Webcam`, `Headphones`, `DockingStation`, `LaptopStand`
- Standalone: `UPS`, `Switch`, `Cable`, `Rack`, `Backpack`, `PowerStrip`, `Pad`
- Ignored: `Service`, `Advance`, `Bundle`, `Other`, `Shipping`

Implementation note: category aliases from invoice `name` values are heuristic, but final category must map to one canonical value.

## Matching Strategy

Match order:

1. Manual overrides
2. Serial number match
3. Model match with category guard
4. Manual resolution pipeline for remaining unresolved items

Confidence levels:

- `high`: serial match
- `medium`: model + brand agreement
- `low`: model match where one side lacks brand data

Serial normalization rules:

- remove `JAR` prefix
- remove leading `S` when serial length suggests wrapper formatting
- remove trailing `N` when serial length suggests wrapper formatting
- case-insensitive comparison
- allow suffix/substring fallback for truncation

Model matching rules:

- normalize obvious noise (trademarks, separators, CPU frequency strings)
- extract critical SKU tokens first
- require category compatibility before model match is accepted

## Manual Matches

Manual match file format:

```csv
invoice_id,invoice_sn,invoice_date,category,brand,model,match_type,hostname,notes
2264559,69ENF0R871366,2022-02-12,SSD,Samsung,980 PRO 2TB,serial,gpu-server-001,
2148749,008NTXRDS794,2020-12-28,Monitor,LG,27GL850-B,manual,martin-ivanov-001,"Desk 3"
```

`match_type` values:

- `serial`
- `model`
- `manual`
- `standalone`
- `ignored`

Parsing requirement:

- manual CSV must be parsed with `std.csv.csvReader` (not string split), including support for quoted fields and embedded commas.

## Invariants

- A single invoice line must not be assigned to more than one host part.
- A single host part must not have more than one selected invoice line.
- Manual matches apply before auto-matching.
- Unresolved items must be explicitly emitted in output.
- Matching behavior must be deterministic for identical inputs.

## Output Contract

The matcher output must include:

- per-host part match results with confidence and match type
- unmatched invoice lines
- standalone manual records
- ignored manual records

Optional reporting extensions can add aggregate statistics, but core output must preserve the fields above.

## Documentation Split

`DESIGN.md` and `STATUS.md` are both needed, with strict roles:

- `DESIGN.md`: normative spec, invariants, contracts, and decisions
- `STATUS.md`: current run results, quality metrics, known issues, and timeline

Rule: if current behavior diverges from this spec, record it in `STATUS.md` as drift and either fix implementation or update this spec with an explicit decision.
