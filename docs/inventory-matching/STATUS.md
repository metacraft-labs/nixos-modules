# Invoice Matching Status

Last updated: 2026-01-24

## Summary

### Host-Side View (what parts matched?)

| Metric | Count | Percentage |
|--------|-------|------------|
| **Hosts parsed** | 19 | - |
| **Total host parts** | 221 | 100% |
| **Matched (high - serial)** | 51 | 23% |
| **Matched (medium - model+brand)** | 30 | 14% |
| **Matched (low - model only)** | 24 | 11% |
| **Total matched** | 105 | 47% |
| **Unmatched parts** | 116 | 53% |

### Invoice-Side View (what invoices matched?)

| Category | Total | Matched | Unmatched | Match % |
|----------|-------|---------|-----------|---------|
| **Host-matchable hardware** | 330 | 93 | 237 | 28% |
| - CPU | 27 | 22 | 5 | 81% |
| - MB | 27 | 22 | 5 | 81% |
| - SSD | 87 | 49 | 38 | 56% |
| - RAM | 53 | 0 | 53 | 0% |
| - Case | 59 | 0 | 59 | 0% |
| - Fan | 46 | 0 | 46 | 0% |
| - PSU | 27 | 0 | 27 | 0% |
| - GPU | 3 | 0 | 3 | 0% |
| - HDD | 1 | 0 | 1 | 0% |
| **Peripherals** | 157 | 10 | 147 | 6% |
| - Monitor | 63 | 0 | 63 | 0% |
| - Mouse | 34 | 1 | 33 | 3% |
| - Keyboard | 26 | 9 | 17 | 35% |
| - Headphones | 26 | 0 | 26 | 0% |
| - Webcam | 8 | 0 | 8 | 0% |
| **Standalone** | 136 | 0 | 136 | n/a |
| - Cable | 62 | 0 | 62 | n/a |
| - UPS | 25 | 0 | 25 | n/a |
| - PowerStrip | 23 | 0 | 23 | n/a |
| - Switch | 22 | 0 | 22 | n/a |
| - Bag | 3 | 0 | 3 | n/a |
| - Rack | 1 | 0 | 1 | n/a |
| **Ignored** | 85 | 0 | 85 | n/a |
| - Service | 29 | 0 | 29 | n/a |
| - Advance | 26 | 0 | 26 | n/a |
| - Bundle | 23 | 0 | 23 | n/a |
| - Other | 4 | 0 | 4 | n/a |
| - Shipping | 3 | 0 | 3 | n/a |
| **(no category)** | 46 | 0 | 46 | 0% |
| **TOTAL** | 754 | 103 | 651 | 14% |

*Note: 754 = expanded invoice entries (after splitting comma-separated SNs from ~395 CSV records)*

## Matching Results by Category

### Unmatched Host Parts (116 total)

| Category | Count | Reason |
|----------|-------|--------|
| RAM | 30 | Host reports only capacity ("64 GB"), not model - unmatchable |
| Keyboard | 29 | USB peripherals, internal controllers (ASRock LED) |
| SSD | 20 | SPCC (JAR SNs ≠ hardware SNs), Crucial (not from JAR), USB drives |
| Mouse | 9 | USB peripherals - require manual assignment |
| CPU | 8 | Apple M3, Dell Xeon, HP, MSI laptops - not from JAR |
| MB | 8 | Apple, Dell, HP, MSI laptops - not from JAR |
| GPU | 6 | RTX 3090s (4), Apple M3 Max (2) - not from JAR |
| Webcam | 4 | USB peripherals - require manual assignment |
| NVME | 2 | Apple SSDs - not from JAR |

### Unmatched Aggregate Invoices (Auto-matchable)

| Category | Count | Notes |
|----------|-------|-------|
| Case | 59 | PC cases (no host detection) |
| RAM | 53 | Need model matching improvements |
| Fan | 46 | CPU coolers (no host detection) |
| SSD | 38 | Need better SN matching |
| PSU | 27 | Power supplies (no host detection) |
| CPU | 5 | Need manual matching |
| MB | 5 | Need manual matching |
| GPU | 3 | Need manual matching |
| HDD | 1 | Rare, manual |

## Data Sources

| File | Entries | Status |
|------|---------|--------|
| `spravkaZahariKaradjov.csv` | 842 | ✅ PRIMARY - Aggregate from JAR |
| `jar-invoices/*.csv` | 708 | ✅ Secondary - Individual invoices |
| `online-hosts-info/*.json` | 30 files (19 hosts) | ✅ Parsed |
| `manual-matches.csv` | 0 | 🔲 To be filled |

## Known Issues

1. ~~**MB brand mismatch**: "ASRock Z790 Pro RS WiFi" matches "MSI PRO Z790-P WIFI" because they share "Z790" tokens~~ **FIXED**: Brand extraction from Bulgarian product descriptions (searches anywhere in text, not just start)
2. **RAM model detection**: Host RAM shows only capacity ("64 GB"), not model - cannot auto-match
3. **No SN for internal components**: CPU, MB, RAM don't expose serial numbers via DMI
4. **Case/Fan/PSU not detectable**: These are installed but not visible to the OS
5. **11 host files not parsing**: Some JSON files may have parse errors or empty hostnames
6. **JAR-assigned SNs**: Silicon Power SSDs have JAR-assigned SNs (JAR16xxxxx) that don't match hardware SNs
7. **Non-JAR hardware**: Apple Macs, HP laptops, Dell servers not from JAR - won't match
8. **Laptop CPUs**: Mobile CPUs (i7-13700H, Ryzen 6850U) are laptop-specific, not from JAR

## Milestones

### M1: Basic Parsing ✅
- [x] Parse CSV files with proper encoding
- [x] Load host-info JSON files (nested "output" structure)
- [x] Basic matching structure

### M2: Category & Matching Rules ✅
- [x] CPU/MB/RAM/SSD/GPU category matching
- [x] Serial number normalization (JAR prefix, S/N suffix removal)
- [x] Model token extraction (strict SKU matching)
- [x] Peripheral categories (Keyboard, Mouse, Webcam)
- [x] Brand normalization

### M3: Manual Matches Integration ✅
- [x] Manual matches CSV loading
- [x] Manual matches applied before auto-matching
- [x] Standalone items tracking in output
- [x] Ignored items tracking in output
- [ ] Fill manual-matches.csv with actual data

### M4: Reporting 🔄
- [x] JSON output with match details
- [x] Confidence levels (high/medium/low)
- [x] Match type tracking (serial/model/manual)
- [x] Export unmatched items for review (--export-unmatched FILE)
- [ ] Statistics summary command

### M5: Complete Coverage 🔲
- [ ] Match all 842 aggregate entries (currently 237 unmatched in auto-matchable categories)
- [ ] Populate manual-matches.csv for peripherals
- [ ] Track standalone items (UPS, switches, cables)
- [ ] Track ignored items (services, advance payments)

## Files

| File | Purpose | Status |
|------|---------|--------|
| `inventory/manual-matches.csv` | Hand-matched entries | ✅ Template created |
| `inventory/standalone-items.csv` | UPS, switches, etc. | 🔲 Not needed (use manual-matches with matchType=standalone) |
| `inventory/ignored-items.csv` | Services, credits | 🔲 Not needed (use manual-matches with matchType=ignored) |

## Recent Changes

- **2026-01-24**: Initial design and status documents created
- **2026-01-24**: Implemented aggregate file parsing with category extraction from code prefixes
- **2026-01-24**: Integrated manual matches - applied before auto-matching, supports standalone/ignored types
- **2026-01-24**: Tightened model matching - SKUs must match exactly (prevents i9-12900K → i9-13900K false positives)
- **2026-01-24**: First full test run: 51 serial matches, 54 model matches, 116 unmatched parts
- **2026-01-24**: Fixed MB brand false positives - brand extraction from product descriptions now enforced
- **2026-01-24**: Added --export-unmatched flag for CSV export of items needing manual review
- **2026-01-24**: Improved brand normalization - MSI/Micro-Star, Silicon Power/SPCC aliases
- **2026-01-24**: Fixed brand extraction for coolers - no longer picks up "Intel" from LGA compatibility text
- **2026-01-24**: Added SSD part number patterns (Crucial CT*, Samsung MZ-*, Kingston SKC*, Lexar NM*)
- **2026-01-24**: CPU model normalization - strips frequency info ("@ 2.80GHz")
- **2026-01-24**: Fixed brand extraction for Bulgarian product descriptions (searches anywhere, not just start)
- **2026-01-24**: Improved confidence levels: high=serial, medium=model+brand, low=model-only
- **2026-01-24**: Added invoice-side statistics (aggregateStats in JSON output) with full category breakdown
