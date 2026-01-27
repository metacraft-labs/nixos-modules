# Invoice Matching System Design

## Overview

This system matches hardware invoice entries from JAR Computers to machine hosts tracked in `online-hosts-info/`. The goal is to ensure **100% accountability** of all invoice items—either automatically matched to a host, manually matched, or categorized as "standalone" items not tied to specific computers.

## Data Sources

### JAR Aggregate File (`spravkaZahariKaradjov.csv`) - PRIMARY

The main aggregate file from JAR Computers containing all purchases. **842 entries**.

Columns:
- `Продажба ID` - Sale/Invoice ID
- `Дата` - Purchase date (YYYY.MM.DD)
- `Продукт` - Full product description (Bulgarian)
- `code` - Product code with category prefix (e.g., `SSDSAMSUNGMZV8P2T0BW`)
- `Брой` - Quantity
- `Единична цена с ДДС` - Unit price with VAT
- `SN` - Serial numbers (comma-separated if multiple)
- `Забележка` - Notes (order number, instructions)

**Advantages**: Cleaner data, grouped items with multiple SNs, reliable product codes.

### Invoice Files (`jar-invoices/`) - SECONDARY

Individual CSV files named `YYYY-MM-DD INVOICE_ID.csv`. **51 files, 708 entries**.

Columns:
- `purchasedbid` - Invoice ID
- `date` - Purchase date
- `name` - Category (CPU, MB, RAM, SSD, GPU, Mouse, KBD, Monitor, UPS, Switch, etc.)
- `mark` - Manufacturer/brand
- `model` - Product model (often inconsistent or missing)
- `sn` - Serial number (may be truncated, prefixed, or formatted differently)
- `price` - Unit price (BGN, excluding VAT)
- `descr` - Full description (Bulgarian, often most reliable source)

### Host Info Files (`online-hosts-info/`)

JSON files with hostname and parts list:
```json
{
  "hostname": "machine-name",
  "parts": [
    { "name": "CPU", "mark": "Intel", "model": "Core i9-13900K", "sn": "" },
    { "name": "SSD", "mark": "", "model": "Samsung SSD 980 PRO 2TB", "sn": "S69ENF0R871366N" }
  ]
}
```

## Item Categories

### Product Code Prefixes (from aggregate file)

The `code` field in the aggregate file has consistent prefixes identifying category:

| Prefix | Category | Normalized | Type |
|--------|----------|------------|------|
| `CPUP` | CPU Intel | CPU | Hardware |
| `CPUA` | CPU AMD | CPU | Hardware |
| `MBIA`, `MBIG`, `MBIM`, `MBAA`, `MBAG` | Motherboard | MB | Hardware |
| `MRAM`, `MSOD` | RAM (Desktop/SO-DIMM) | RAM | Hardware |
| `SSDS`, `SSDK`, `SSDL`, `SSDA` | SSD (Samsung/Kingston/Lexar/A-Data) | SSD | Hardware |
| `HDDP` | HDD | HDD | Hardware |
| `VCRF` | GPU/Video Card | GPU | Hardware |
| `FANC`, `FANN` | Cooler/Fan | Fan | Hardware |
| `PWRP`, `PWRPC` | Power Supply | PSU | Hardware |
| `CASE` | PC Case | Case | Hardware |
| `KBDU`, `KBLO`, `KBRA`, `KBDA`, `KBCH`, `KBST` | Keyboard | Keyboard | Peripheral |
| `MOLO`, `MORA`, `MSUS`, `MOA4` | Mouse | Mouse | Peripheral |
| `MNLC` | Monitor | Monitor | Peripheral |
| `FWEB` | Webcam | Webcam | Peripheral |
| `MULH` | Headphones/Audio | Headphones | Peripheral |
| `MOPL`, `MOPG`, `MOPR` | Mouse Pad | Pad | Standalone |
| `UPSC`, `UPSP` | UPS | UPS | Standalone |
| `NTLH`, `SWTP` | Switch | Switch | Standalone |
| `CNCP`, `CAVM` | Cable | Cable | Standalone |
| `NTRF` | Network Rack | Rack | Standalone |
| `ACCN` | Bag/Backpack | Bag | Standalone |
| `URRO`, `UROK`, `URAL`, `URHA` | Power Strip | PowerStrip | Standalone |
| `USLA`, `USLR` | Assembly Service | Service | Ignored |
| `_AVA` | Advance Payment | Advance | Ignored |
| `_PC_` | Computer Bundle | Bundle | Ignored |
| `_OTH` | Other/Credit Note | Other | Ignored |
| `XXXX` | Shipping | Shipping | Ignored |

### Auto-Matchable (to hosts)

Items that should be matched to specific machines:

| Invoice Category | Normalized | Notes |
|-----------------|------------|-------|
| CPU | CPU | Intel Core, AMD Ryzen |
| MB, Mainboards | MB | Motherboards |
| RAM, RAM 16GB, Ram, Memory | RAM | Various capacities |
| SSD, SSD дискове | SSD | NVMe, SATA |
| GPU, Video, Graphics | GPU | NVIDIA, AMD |
| Fan, Cooler | Fan | CPU coolers, AIO |
| Power Supply | PSU | ATX power supplies |
| Case, Кутия | Case | PC cases |

### Manually-Matchable (peripherals assigned to hosts)

Items that may be assigned to hosts but cannot be auto-detected:

| Invoice Category | Type | Notes |
|-----------------|------|-------|
| KBD, Keyboard, Клавиатура | Keyboard | Some detectable via USB |
| Mouse, Мишка | Mouse | Some detectable via USB |
| Headphones, Слушалки | Headphones | Bluetooth/USB |
| Monitor, Монитор | Monitor | Via display info |
| Webcam, Camera | Webcam | USB devices |

### Standalone Items (not matched to hosts)

Items tracked separately, not assigned to machines:

| Invoice Category | Type | Notes |
|-----------------|------|-------|
| UPS | UPS | Uninterruptible power supplies |
| Switch | Switch | Network switches |
| LAN | Cable/Network | Ethernet cables, racks |
| Чанта, Раница | Bag | Laptop bags, backpacks |
| Other | Misc | Cable channels, adapters |
| Услуги | Service | Assembly, warranty services |
| (negative price) | Credit/Advance | Advance payments, discounts |

## Matching Strategies

### 1. Serial Number Match (High Confidence)

Match invoice SN to host part SN with normalization:

```
Host SN:    S69ENF0R871366N
Invoice SN: 69ENF0R871366
→ Match after removing prefix 'S' and suffix 'N'
```

Normalization rules:
- Remove `JAR` prefix
- Remove leading `S` if SN length > 10
- Remove trailing `N` if SN length > 10
- Case-insensitive comparison
- Substring/suffix matching for truncated SNs

### 2. Model + Brand Match (Medium Confidence)

When SN unavailable, match by product model and brand:

```
Host:    model="12th Gen Intel(R) Core(TM) i9-12900K"
Invoice: model="Core i9-12900K", mark="Intel"
→ Match via token extraction: "I9", "12900K"
```

Token extraction patterns:
- CPU tier: `I[3579]` → i3, i5, i7, i9
- CPU SKU: `\d{4,5}[A-Z]*` → 12900K, 7950X, 5800X3D
- GPU: `(RTX|GTX|RX)?\d{3,4}(TI|XT)?` → RTX4090, GTX1080

### 3. Category + Description Match (Low Confidence)

For items without SN or clear model, use category + fuzzy description matching.

## File Structure

```
inventory/
├── jar-invoices/           # Source CSV files
├── online-hosts-info/      # Host JSON files
├── manual-matches.csv      # Hand-matched entries
├── standalone-items.csv    # Items not tied to hosts
└── ignored-items.csv       # Services, credits, etc.

docs/inventory-matching/
├── DESIGN.md              # This file
└── STATUS.md              # Progress tracking
```

## Manual Matches CSV Format

```csv
invoice_id,invoice_sn,invoice_date,category,brand,model,match_type,hostname,notes
2264559,69ENF0R871366,2022-02-12,SSD,Samsung,980 PRO 2TB,serial,gpu-server-001,
2148749,008NTXRDS794,2020-12-28,Monitor,LG,27GL850-B,manual,martin-ivanov-001,Desk 3
```

Columns:
- `invoice_id` - From CSV filename
- `invoice_sn` - Original serial number from invoice
- `invoice_date` - Purchase date
- `category` - Normalized category
- `brand` - Manufacturer
- `model` - Product model
- `match_type` - `serial`, `model`, `manual`, `standalone`, `ignored`
- `hostname` - Target host (empty for standalone/ignored)
- `notes` - Optional notes (desk location, etc.)

## Implementation Phases

### Phase 1: Core Infrastructure ✅
- [x] Parse all CSV files robustly (handle malformed rows)
- [x] Load all host-info JSON files (with nested "output" structure)
- [x] Implement category normalization from code prefixes

### Phase 2: Auto-Matching ✅
- [x] Serial number normalization and matching
- [x] Model token extraction and matching (strict SKU matching)
- [x] Brand normalization

### Phase 3: Manual Matching Support ✅
- [x] Load manual-matches.csv
- [x] Apply manual matches before auto-matching (override behavior)
- [x] Track standalone items (matchType=standalone)
- [x] Track ignored items (matchType=ignored)

### Phase 4: Reporting 🔄
- [x] JSON output with match details
- [ ] Generate match statistics summary
- [ ] Export unmatched items for manual review (CSV format)
- [ ] Validate no duplicate matches

## Success Metrics

| Metric | Target | Current |
|--------|--------|---------|
| Total invoices parsed | 100% | TBD |
| Auto-matched (serial) | - | TBD |
| Auto-matched (model) | - | TBD |
| Manually matched | - | TBD |
| Standalone items | - | TBD |
| Ignored items | - | TBD |
| Unaccounted items | 0% | TBD |
