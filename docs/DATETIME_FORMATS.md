# DateTime Format Support

## Overview
The semaphore wrapper now supports **multiple datetime formats** for `RestoreDateTime` parameter. The system automatically detects and normalizes various input formats to the standard `yyyy-MM-dd HH:mm:ss` format.

---

## ✅ Supported Formats

### 1. **Standard Format (Recommended)**
**ISO 8601 format - Most portable and unambiguous**

```
Format: yyyy-MM-dd HH:mm:ss
Examples:
  • 2025-10-11 14:30:00
  • 2025-01-15 09:45:30
  • 2025-12-31 23:59:59
```

**Advantages:**
- ✅ Unambiguous (no MM/DD vs DD/MM confusion)
- ✅ Sortable
- ✅ International standard
- ✅ Works in all locales

---

### 2. **ISO 8601 Variations**

```
Format: yyyy-MM-ddTHH:mm:ss
Example: 2025-10-11T14:30:00

Format: yyyy-MM-dd HH:mm
Example: 2025-10-11 14:30  (seconds default to :00)

Format: yyyy-MM-dd
Example: 2025-10-11  (time defaults to 00:00:00)
```

---

### 3. **US Format**
**Month/Day/Year - Common in United States**

```
Format: M/d/yyyy h:mm:ss tt  (12-hour with AM/PM)
Examples:
  • 10/11/2025 2:30:00 PM
  • 1/5/2025 9:15:30 AM

Format: M/d/yyyy H:mm:ss  (24-hour)
Examples:
  • 10/11/2025 14:30:00
  • 1/5/2025 09:15:30

Format: M/d/yyyy h:mm tt  (without seconds)
Examples:
  • 10/11/2025 2:30 PM
  • 1/5/2025 9:15 AM

Format: M/d/yyyy  (date only)
Examples:
  • 10/11/2025
  • 1/5/2025
```

**Note:** Leading zeros are optional: `1/5/2025` = `01/05/2025`

---

### 4. **European Format**
**Day/Month/Year - Common in Europe and many other countries**

```
Format: dd/MM/yyyy HH:mm:ss
Examples:
  • 11/10/2025 14:30:00  (11th October 2025)
  • 05/01/2025 09:15:30  (5th January 2025)

Format: d/M/yyyy H:mm:ss  (without leading zeros)
Examples:
  • 11/10/2025 14:30:00
  • 5/1/2025 9:15:30

Format: dd/MM/yyyy  (date only)
Examples:
  • 11/10/2025
  • 05/01/2025
```

**⚠️ Warning:** Be careful with European vs US format ambiguity!
- `01/02/2025` could be Jan 2 (US) or Feb 1 (European)
- Use ISO format `2025-01-02` to avoid confusion

---

### 5. **Alternative Separators**

#### **Dot Separator**
```
Format: yyyy.MM.dd HH:mm:ss
Examples:
  • 2025.10.11 14:30:00
  • 2025.01.05 09:15:30

Format: dd.MM.yyyy HH:mm:ss
Examples:
  • 11.10.2025 14:30:00
  • 05.01.2025 09:15:30
```

#### **Dash Separator**
```
Format: dd-MM-yyyy HH:mm:ss
Examples:
  • 11-10-2025 14:30:00
  • 05-01-2025 09:15:30

Format: MM-dd-yyyy HH:mm:ss
Examples:
  • 10-11-2025 14:30:00
  • 01-05-2025 09:15:30
```

---

## 🔍 How It Works

### Parsing Priority

The system tries formats in this order:

1. **Exact Format Matching** - Tries ~20 predefined formats
2. **Automatic Parsing** - Uses .NET's culture-aware parsing as fallback
3. **Error** - If all attempts fail, shows helpful error message

### Normalization

All inputs are converted to: `yyyy-MM-dd HH:mm:ss`

**Examples:**
```
Input:  10/11/2025 2:30 PM
Output: 2025-10-11 14:30:00

Input:  11.10.2025
Output: 2025-10-11 00:00:00

Input:  2025-10-11T14:30:00
Output: 2025-10-11 14:30:00
```

---

## 💡 Usage Examples

### Via Wrapper Script

```powershell
# Standard format (recommended)
./semaphore_wrapper.ps1 "RestoreDateTime=2025-10-11 14:30:00" "Source=dev"

# ISO 8601 with T separator
./semaphore_wrapper.ps1 "RestoreDateTime=2025-10-11T14:30:00" "Source=dev"

# US format with AM/PM
./semaphore_wrapper.ps1 "RestoreDateTime=10/11/2025 2:30 PM" "Source=dev"

# European format
./semaphore_wrapper.ps1 "RestoreDateTime=11/10/2025 14:30:00" "Source=dev"

# Date only (time defaults to midnight)
./semaphore_wrapper.ps1 "RestoreDateTime=2025-10-11" "Source=dev"
```

### Direct Script Call

```powershell
# Standard format
./RestorePointInTime.ps1 -source "dev" -RestoreDateTime "2025-10-11 14:30:00" -Timezone "UTC"

# Any supported format
./RestorePointInTime.ps1 -source "dev" -RestoreDateTime "10/11/2025 2:30 PM" -Timezone "America/Los_Angeles"
```

---

## ⚠️ Common Pitfalls

### 1. **US vs European Format Ambiguity**

```
Input: 01/02/2025

US interpretation:     January 2, 2025
European interpretation: February 1, 2025
```

**Solution:** Use ISO format to avoid ambiguity
```
Use: 2025-01-02  (unambiguous)
```

---

### 2. **Missing Time Component**

When you provide only a date, time defaults to midnight (00:00:00):

```
Input:  2025-10-11
Output: 2025-10-11 00:00:00

Interpretation: Restore to the START of October 11, 2025
```

**If you want a specific time:**
```
Use: 2025-10-11 14:30:00
```

---

### 3. **Timezone is Separate**

DateTime format is independent of timezone:

```
✅ Correct:
RestoreDateTime=2025-10-11 14:30:00
Timezone=America/Los_Angeles

❌ Don't include timezone in datetime:
RestoreDateTime=2025-10-11 14:30:00 PST  (won't parse)
```

---

## 🔧 Testing

Run the test suite to verify all formats work:

```powershell
./scripts/tests/test_datetime_parsing.ps1
```

**Expected output:**
```
╔═══════════════════════════════════════════════════════════╗
║        DateTime Parsing Test Suite                       ║
╚═══════════════════════════════════════════════════════════╝

Running 23 test cases...

✅ PASS: Standard ISO format with time
   Input: '2025-10-11 14:30:00'
   Output: '2025-10-11 14:30:00'
   Format: yyyy-MM-dd HH:mm:ss

... (more tests) ...

╔═══════════════════════════════════════════════════════════╗
║                    TEST SUMMARY                           ║
╚═══════════════════════════════════════════════════════════╝

Total Tests: 23
Passed: 23
Failed: 0
Pass Rate: 100%

🎉 All tests passed!
```

---

## 🚨 Error Messages

If parsing fails, you'll see a helpful error:

```
❌ FATAL ERROR: Could not parse datetime: 'invalid-date'
   Please use one of these formats:
   • Standard: 2025-01-15 14:30:00 (recommended)
   • ISO 8601: 2025-01-15T14:30:00
   • US Format: 1/15/2025 2:30:00 PM
   • European: 15/01/2025 14:30:00
   • Date Only: 2025-01-15 (time defaults to 00:00:00)

Examples of valid inputs:
  • 2025-10-11 14:30:00
  • 10/11/2025 2:30 PM
  • 11/10/2025 14:30:00
  • 2025-10-11
```

---

## 📊 Format Comparison Table

| Format Type | Example | Ambiguous? | Sortable? | Recommended? |
|-------------|---------|------------|-----------|--------------|
| ISO 8601 | `2025-10-11 14:30:00` | ❌ No | ✅ Yes | ✅ **Best** |
| ISO T | `2025-10-11T14:30:00` | ❌ No | ✅ Yes | ✅ Good |
| US | `10/11/2025 2:30 PM` | ⚠️ Yes | ❌ No | ⚠️ Use carefully |
| European | `11/10/2025 14:30:00` | ⚠️ Yes | ❌ No | ⚠️ Use carefully |
| Dot | `2025.10.11 14:30:00` | ❌ No | ✅ Yes | ✅ Good |

---

## 🎯 Best Practices

### ✅ Do This
```powershell
# Use ISO 8601 format (no ambiguity)
RestoreDateTime="2025-10-11 14:30:00"

# Be explicit about time if needed
RestoreDateTime="2025-10-11 00:00:00"  # Start of day
RestoreDateTime="2025-10-11 23:59:59"  # End of day

# Document which format you're using in comments
# Restore to October 11, 2025 at 2:30 PM
RestoreDateTime="2025-10-11 14:30:00"
```

### ❌ Don't Do This
```powershell
# Ambiguous date (could be Oct 1 or Jan 10)
RestoreDateTime="10/01/2025"

# Including timezone in datetime (wrong)
RestoreDateTime="2025-10-11 14:30:00 PST"

# Using only date when specific time matters
RestoreDateTime="2025-10-11"  # Defaults to 00:00:00!
```

---

## 📚 Related Documentation

- **Timezone Configuration**: See `Get-AzureParameters.ps1` documentation
- **Wrapper Script**: See `semaphore_wrapper.ps1` comments
- **Restore Script**: See `RestorePointInTime.ps1` documentation

---

## 🔄 Migration from Old Format

**No changes needed!** The old format still works:

```powershell
# Old (still works)
RestoreDateTime="2025-10-11 14:30:00"

# New (also works now)
RestoreDateTime="10/11/2025 2:30 PM"
RestoreDateTime="11.10.2025 14:30:00"
RestoreDateTime="2025-10-11T14:30:00"
```

---

*Last Updated: 2025-10-11*  
*Documentation for: semaphore_wrapper.ps1 v2.0*

