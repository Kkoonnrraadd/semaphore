# DateTime Format Ambiguity - Explained

## ⚠️ The Problem with Ambiguous Dates

When users input dates like `11/10/2025`, it could mean:
- **US Format (MM/DD)**: November 10, 2025
- **European Format (DD/MM)**: October 11, 2025

This is a **fundamental ambiguity** that cannot be resolved without additional context.

---

## 🔍 How Our Parser Handles Ambiguity

The parser tries formats in a **specific order** (priority-based):

### **Priority Order:**
```
1. Standard formats (yyyy-MM-dd, yyyy-MM-ddTHH:mm:ss) ✅ No ambiguity
2. US formats (M/d/yyyy)                              ⚠️ Tries US first
3. European formats (dd/MM/yyyy)                      ⚠️ Tries after US
4. Alternative separators (dots, dashes)              ⚠️ Various priorities
5. Automatic parsing                                  ⚠️ Culture-dependent
```

### **Result:**
- **Unambiguous dates** (like `15/01/2025`) work correctly regardless of format
  - Can only be January 15 (no month 15)
  
- **Ambiguous dates** (like `11/10/2025`) are parsed as **US format first**
  - Result: November 10, 2025 (not October 11)

---

## 📊 Test Results Explained

### ✅ **Unambiguous Formats (Always Work)**

These formats have **no ambiguity**:

```
✅ 2025-10-11 14:30:00     (ISO 8601 - YYYY-MM-DD)
✅ 2025-10-11T14:30:00     (ISO with T separator)
✅ 15/01/2025              (No month 15 - must be Jan 15)
✅ 31/12/2025              (No month 31 - must be Dec 31)
✅ 2025.10.11              (YYYY.MM.DD with dots)
```

**Recommendation: Always use these formats!**

---

### ⚠️ **Ambiguous Formats (Depend on Parser Priority)**

#### **Example 1: `11/10/2025 14:30:00`**

**Could be:**
- US: November 10, 2025 ← **Parser chooses this**
- European: October 11, 2025

**Test Result:**
```
Input:    11/10/2025 14:30:00
Expected: 2025-11-10 14:30:00  (US format)
Result:   ✅ PASS
```

**Why?** Parser tries US format (M/d/yyyy) before European (dd/MM/yyyy).

---

#### **Example 2: `5/1/2025`**

**Could be:**
- US: May 1, 2025 ← **Parser chooses this**
- European: January 5, 2025

**Test Result:**
```
Input:    5/1/2025
Expected: 2025-05-01 00:00:00  (US format)
Result:   ✅ PASS
```

**Why?** Single-digit format `M/d/yyyy` tried before `d/M/yyyy`.

---

#### **Example 3: `10-11-2025 14:30:00`**

**Could be:**
- DD-MM-YYYY: November 10, 2025 ← **Parser chooses this**
- MM-DD-YYYY: October 11, 2025

**Test Result:**
```
Input:    10-11-2025 14:30:00
Expected: 2025-11-10 14:30:00  (DD-MM format)
Result:   ✅ PASS
```

**Why?** With dash separator, parser tries `dd-MM-yyyy` before `MM-dd-yyyy`.

---

## 🎯 How to Avoid Ambiguity

### **1. Use ISO 8601 Format (Best)**
```powershell
✅ RECOMMENDED: "2025-10-11 14:30:00"
```

**Advantages:**
- Zero ambiguity
- International standard
- Sortable
- Machine-readable

---

### **2. Use Unambiguous Dates**
```powershell
✅ Good: "15/01/2025"     (Can only be Jan 15)
✅ Good: "31/12/2025"     (Can only be Dec 31)
✅ Good: "13/05/2025"     (Can only be May 13)

⚠️ Ambiguous: "11/10/2025"  (Nov 10 or Oct 11?)
⚠️ Ambiguous: "5/1/2025"    (May 1 or Jan 5?)
```

---

### **3. Add Explicit Separators**
```powershell
✅ Good: "2025.10.11"     (Clearly YYYY.MM.DD)
✅ Good: "11.10.2025"     (Clearly DD.MM.YYYY with dots)

⚠️ Ambiguous: "11/10/2025"  (Could be either format)
```

---

### **4. Use 12-hour Format with AM/PM**
```powershell
✅ Good: "10/11/2025 2:30 PM"
```

**Why?** The `h:mm tt` pattern with AM/PM is **uniquely US format**, so parser knows it's US date too.

---

## 🔬 Parser Behavior Matrix

| Input Format | Example | Parser Interpretation | Ambiguous? |
|--------------|---------|----------------------|------------|
| `yyyy-MM-dd` | `2025-10-11` | Year-Month-Day | ❌ No |
| `yyyy.MM.dd` | `2025.10.11` | Year-Month-Day | ❌ No |
| `dd.MM.yyyy` | `11.10.2025` | Day-Month-Year | ❌ No |
| `M/d/yyyy h:mm tt` | `10/11/2025 2:30 PM` | Month-Day-Year | ❌ No (AM/PM indicates US) |
| `dd/MM/yyyy` | `15/01/2025` | Day-Month-Year | ❌ No (15 can't be month) |
| `M/d/yyyy` | `11/10/2025` | Month-Day-Year | ⚠️ **YES** (could be DD/MM) |
| `M/d/yyyy` | `5/1/2025` | Month-Day-Year | ⚠️ **YES** (could be D/M) |
| `dd-MM-yyyy` | `10-11-2025` | Day-Month-Year | ⚠️ **YES** (could be MM-DD) |

---

## 💡 Best Practices for Users

### ✅ **Do This**

```powershell
# Use ISO 8601 format
RestoreDateTime="2025-10-11 14:30:00"

# Document your intent with comments
# Restore to October 11, 2025 at 2:30 PM
RestoreDateTime="2025-10-11 14:30:00"

# Use unambiguous dates
RestoreDateTime="15/01/2025 14:30:00"  # Clearly Jan 15

# Use AM/PM for US format
RestoreDateTime="10/11/2025 2:30 PM"   # Clearly US format
```

---

### ❌ **Avoid This**

```powershell
# Ambiguous slashes without AM/PM
RestoreDateTime="11/10/2025 14:30:00"  # Nov 10 or Oct 11?

# Ambiguous single digits
RestoreDateTime="5/1/2025"  # May 1 or Jan 5?

# Ambiguous dashes
RestoreDateTime="10-11-2025"  # Nov 10 or Oct 11?
```

---

## 🧪 Testing Your Input

**Want to test how the parser interprets your input?**

```powershell
# Run the test suite
./scripts/tests/test_datetime_parsing.ps1

# Or test a specific datetime using the wrapper in dry-run mode
./semaphore_wrapper.ps1 "RestoreDateTime=YOUR_DATE" "Source=dev" "DryRun=true"
```

**Example output:**
```
📅 Parsing datetime input: '11/10/2025 14:30:00'
  ✅ Parsed successfully using format: M/d/yyyy H:mm:ss
  ✅ Normalized to: 2025-11-10 14:30:00

🕐 Using timezone from SEMAPHORE_SCHEDULE_TIMEZONE: UTC
```

This shows you **exactly** how the parser interpreted your input!

---

## 🌍 Regional Considerations

Different regions have different default formats:

| Region | Common Format | Example |
|--------|---------------|---------|
| **USA** | MM/DD/YYYY | 10/11/2025 = Oct 11 |
| **Europe** | DD/MM/YYYY | 10/11/2025 = Nov 10 |
| **Asia (ISO)** | YYYY-MM-DD | 2025-10-11 = Oct 11 |
| **Japan** | YYYY.MM.DD | 2025.10.11 = Oct 11 |

**Our parser defaults to US format for ambiguous slashes.**

---

## 🔧 For Developers

### **Adding a New Format**

To add support for a new format, update the `$formats` array in `semaphore_wrapper.ps1`:

```powershell
$formats = @(
    # ... existing formats ...
    
    # Your new format
    'your-format-pattern',  # Brief description
)
```

**Priority matters!** Formats are tried in order.

---

### **Handling Regional Preferences**

If you need to prioritize European format, reorder the formats:

```powershell
$formats = @(
    # Standard formats first (no change)
    'yyyy-MM-dd HH:mm:ss',
    
    # European formats BEFORE US
    'dd/MM/yyyy HH:mm:ss',  # Move up
    'dd/MM/yyyy',
    
    # Then US formats
    'M/d/yyyy H:mm:ss',
    'M/d/yyyy',
)
```

---

## 📝 Summary

### **Key Takeaways:**

1. **Always prefer ISO 8601 format**: `yyyy-MM-dd HH:mm:ss`
2. **Ambiguous dates are parsed as US format first** (when using slashes)
3. **Unambiguous dates work correctly** regardless of format
4. **Test your input** using dry-run mode if unsure
5. **Document your datetime intent** with comments

### **Quick Reference:**

```
✅ No Ambiguity:  2025-10-11 14:30:00  (ISO 8601)
✅ No Ambiguity:  15/01/2025           (No month 15)
⚠️ Ambiguous:     11/10/2025          (Parsed as Nov 10)
⚠️ Ambiguous:     5/1/2025            (Parsed as May 1)
```

---

*Last Updated: 2025-10-11*  
*Related: DATETIME_FORMATS.md, test_datetime_parsing.ps1*

