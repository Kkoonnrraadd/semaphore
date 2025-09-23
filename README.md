# PowerShell Self-Service Data Refresh for Semaphore

A clean, PowerShell-only automation system for Azure data refresh operations, designed specifically for Semaphore CI/CD.

## 🚀 Features

- **Pure PowerShell** - No Ansible dependencies
- **Semaphore Integration** - Direct template execution
- **Azure US Government** - Full support for government cloud
- **Secure Credentials** - Variable Groups integration
- **Comprehensive Logging** - Detailed operation tracking
- **Modular Design** - Organized script structure

## 📁 Repository Structure

```
├── scripts/                          # All PowerShell scripts
│   ├── main/self_service.ps1         # Main orchestration script
│   ├── restore/                      # Database restore operations
│   ├── environment/                  # Environment start/stop
│   ├── database/                     # Database operations
│   ├── storage/                      # Storage/attachment operations
│   ├── configuration/                # Configuration management
│   ├── replicas/                     # Replica management
│   ├── permissions/                  # Permission management
│   └── common/                       # Shared utilities
├── .semaphore/                       # Semaphore configuration
│   ├── templates/                    # Task templates
│   └── semaphore.yml                 # Pipeline configuration
├── config/                           # Configuration files
├── logs/                             # Log files
└── docs/                             # Documentation
```

## 🔧 Quick Start

### 1. Set Up Credentials
Create Variable Groups in Semaphore with:
- `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID` (Service Principal)
- OR `AZURE_USERNAME`, `AZURE_PASSWORD` (Username/Password)

### 2. Run via Semaphore Templates
- **Dry Run**: Use "Self-Service Data Refresh - DRY RUN" template
- **Production**: Use "Self-Service Data Refresh - PRODUCTION" template

### 3. Direct Execution
```bash
# Dry run
pwsh scripts/main/self_service.ps1 -DryRun -AutoApprove

# Production
pwsh scripts/main/self_service.ps1 -AutoApprove
```

## 📋 Supported Operations

1. **Restore Point in Time** - Database point-in-time recovery
2. **Environment Management** - Stop/Start Azure environments  
3. **Database Operations** - Copy databases between environments
4. **Storage Operations** - Copy attachments and files
5. **Configuration Management** - Clean up and adjust configurations
6. **Replica Management** - Handle database replicas
7. **Permission Management** - Configure SQL users and permissions

## 🔐 Security

- Credentials stored in Semaphore Variable Groups
- Azure US Government cloud support
- Comprehensive logging for audit trails
- Dry run mode for safe testing

## 📖 Documentation

See the `docs/` folder for detailed documentation on setup, usage, and troubleshooting.

---

**Migration from Ansible**: This repository has been converted from an Ansible-based system to a pure PowerShell implementation for better maintainability and direct Semaphore integration.

**my notes**
cd /home/kgluza/Manufacturo/semaphore && sleep 3 && docker compose exec semaphore pwsh -File scripts/main/self_service.ps1 -DryRun -AutoApprove

# Dry run (safe testing)
docker compose exec semaphore pwsh scripts/main/self_service.ps1 -DryRun -AutoApprove

# Production run
docker compose exec semaphore pwsh scripts/main/self_service.ps1 -AutoApprove

scripts/main/self_service.ps1 -Source {{ .source_env }} -Destination {{ .dest_env }} -SourceNamespace {{ .source_ns }} -DestinationNamespace {{ .dest_ns }} -CustomerAlias {{ .customer }} -RestoreDateTime "{{ .restore_datetime }}" -Timezone {{ .timezone }} -Cloud {{ .cloud }} -MaxWaitMinutes {{ .max_wait }} -DryRun -AutoApprove