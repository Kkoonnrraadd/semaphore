# 🚀 Simple Template Import Guide

## **What you wanted:** Use your existing `.semaphore/templates/` files

✅ **Solution:** Dynamic script that reads ANY JSON template files and imports them via API

## **How to use it:**

### **Method 1: Simple import** (30 seconds)
```bash
./import-templates.sh
```

### **Method 2: With configuration file** (Better for multiple repos)
```bash
# Uses semaphore-config.json for settings
./import-templates-with-config.sh
```

That's it! Your `.semaphore/templates/` files are now imported into Semaphore.

## **For multiple repositories:**

### **Step 1: Copy files to each repo**
```bash
# Copy these files to each repository:
cp import-templates.sh /path/to/other/repo/
cp semaphore-config.json /path/to/other/repo/
```

### **Step 2: Update config for each repo**
Edit `semaphore-config.json` in each repo:
```json
{
  "semaphore_url": "http://localhost:3001",  # Different port per environment
  "project_id": "2",                        # Different project per environment
  "template_directory": ".semaphore/templates",
  "repository_settings": {
    "repository_id": 2,                     # Adjust per repo
    "inventory_id": 2,
    "environment_id": 5
  }
}
```

### **Step 3: Run in each repo**
```bash
cd /path/to/repo1 && ./import-templates-with-config.sh
cd /path/to/repo2 && ./import-templates-with-config.sh
```

## **What you get:**
- ✅ **Dynamic reading** - Works with ANY JSON template files
- ✅ **Configuration-driven** - Easy to customize per repo/environment
- ✅ **Reusable** - Copy to any repository and run
- ✅ **Flexible** - Supports different Semaphore instances

## **Files you have:**
- ✅ `import-templates.sh` - Simple version  
- ✅ `import-templates-with-config.sh` - Configuration-driven version
- ✅ `semaphore-config.json` - Configuration template
- ✅ `test-token.sh` - Test if API works

**Perfect for scaling across multiple repos! 🎯**
